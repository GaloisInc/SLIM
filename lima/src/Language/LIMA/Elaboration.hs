-- |
-- Module: Elaboration
-- Description: -
-- Copyright: (c) 2013 Tom Hawkins & Lee Pike

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Language.LIMA.Elaboration
  (
  -- * Atom monad and container.
    Atom
  , CompCtx  (..)
  , defCCtx
  , defSCtx
  , AtomDB   (..)
  , Global   (..)
  , Rule     (..)
  , ChanInfo (..)
  , StateHierarchy (..)
  , buildAtom
  -- * Type Aliases and Utilities
  , Phase (..)
  , elaborate
  , var
  , var'
  , array
  , array'
  , addName
  , allUVs
  , allUEs
  , isHierarchyEmpty
  , initialGlobal
  , getChannels
  ) where

import qualified Control.Monad.State.Strict as S

import Data.Function (on)
import Data.Char (isAlpha, isAlphaNum)
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust, isNothing)

import MonadLib
import MonadLib.Derive

import Language.LIMA.Types
import Language.LIMA.Channel.Types
import Language.LIMA.Expressions hiding (typeOf)
import Language.LIMA.UeMap


-- | Global data kept in each 'Atom' monad computation.
data Global = Global
  { gRuleId    :: Int  -- ^ integer supply for rule IDs
  , gVarId     :: Int  -- ^ integer supply for variable IDs
  , gArrayId   :: Int  -- ^ integer supply for array IDs
  , gChannelId :: Int  -- ^ integer supply for channel IDs
  , gClockId   :: Int  -- ^ integer supply for clock IDs
  , gState     :: [StateHierarchy]  -- ^ global state hierarchies
  , gProbes    :: [(String, Hash)]  -- ^ probe names and expression hashes
  , gPeriod    :: Int               -- ^ Atom global period, used by sub-atoms
                                    --   that don't specify a period
  , gPhase     :: Phase             -- ^ Atom global phase
  }
  deriving (Show)

-- | Initial global state for the 'Atom' monad.
initialGlobal :: Global
initialGlobal = Global
  { gRuleId    = 0
  , gVarId     = 0
  , gArrayId   = 0
  , gChannelId = 0
  , gClockId = 0
  , gState     = []
  , gProbes    = []
  , gPeriod    = 1
  , gPhase     = MinPhase 0
  }

-- | The atom database value. This is an intermediate representation of an atom
-- computation.
data AtomDB = AtomDB
  { -- | Internal Atom identifier
    atomId          :: Int
    -- | Atom name
  , atomName        :: Name
    -- | Names used at this level.
  , atomNames       :: [Name]
    -- | Enabling condition.
  , atomEnable      :: Hash
    -- | Non-hereditary component on enable cond
  , atomEnableNH    :: Hash
    -- | Sub atoms.
  , atomSubs        :: [AtomDB]
    -- | Atom period, if not the default of 1 then the global period is used
  , atomPeriod      :: Int
    -- | Atom phase constraint
  , atomPhase       :: Phase
    -- | Sequence of (variable, shared expr) assignments arising from '<=='
  , atomAssigns     :: [(MUV, Hash)]
    -- | Sequence of custom actions to take (only supported by the C code
    --   generator), see 'action'
  , atomActions     :: [([String] -> String, [Hash])]
    -- | Sequence of assertion statements
  , atomAsserts     :: [(Name, Hash)]
    -- | Sequence of coverage statements
  , atomCovers      :: [(Name, Hash)]
    -- | Set of (channel input, channel value hash) pairs for writes
  , atomChanWrite   :: [(ChanInput, Hash, ChannelDelay)]
    -- | Set of channel outputs which are read by the atom
  , atomChanRead    :: [ChanOutput]
    -- | Set of channel initializations
  , atomChanInit    :: [(ChanInput, Const, ChannelDelay)]
  }

-- | Show AtomDB instance for debugging purposes.
instance Show AtomDB where
  show a = "AtomDB { " ++ intercalate ", " [ show (atomId a)
                                           , atomName a
                                           , "subs " ++ show (length (atomSubs a))
                                           , "per " ++ show (atomPeriod a)
                                           , "pha " ++ show (atomPhase a)
                                           ] ++ " }"  -- TODO more detail?
instance Eq   AtomDB where (==) = (==) `on` atomId
instance Ord  AtomDB where compare a b = compare (atomId a) (atomId b)

-- | A 'Rule' corresponds to an atomic action of one of three forms:
--
--   1. an atomic computation, e.g. variable assignment, channel reads and
--   writes.
--   2. an assertion statement
--   3. a coverage statement
--
-- XXX sum of records leads to partial record field functions
data Rule
  = -- | An atomic computation. All the fields, except for 'ruleEnable' and
    --   'ruleEnableNH' are simply copied from a corresponding 'AtomDB' value.
    Rule
    { ruleId          :: Int
    , ruleName        :: Name
    , ruleEnable      :: Hash
    , ruleEnableNH    :: Hash
    , ruleAssigns     :: [(MUV, Hash)]
    , ruleActions     :: [([String] -> String, [Hash])]
    , rulePeriod      :: Int
    , rulePhase       :: Phase
    , ruleChanWrite   :: [(ChanInput, Hash, ChannelDelay)]
    , ruleChanRead    :: [ChanOutput]
    , ruleChanInit    :: [(ChanInput, Const, ChannelDelay)]
    }
  | -- | An assertion statement
    Assert
    { ruleName      :: Name
    , ruleEnable    :: Hash
    , ruleEnableNH  :: Hash
    , ruleAssert    :: Hash
    }
  | -- | A coverage statement
    Cover
    { ruleName      :: Name
    , ruleEnable    :: Hash
    , ruleEnableNH  :: Hash
    , ruleCover     :: Hash
    }

-- | Show Rule instance, mainly for debugging.
instance Show Rule where
  show r@Rule{} = "Rule { " ++ intercalate ", " [ show (ruleId r)
                                                , ruleName r
                                                -- , show (ruleEnable r)
                                                -- , show (ruleEnableNH r)
                                                ] ++ " }"  -- TODO more detail?
  show _r@Assert{} = "Assert{}"
  show _r@Cover{} = "Cover{}"

-- | Compiled channel info used to return channel info from the elaboration
-- functions.
data ChanInfo = ChanInfo
  { cinfoSrc       :: Maybe Int   -- ^ ruleId of source, either this or next is set
  , cinfoRecv      :: Maybe Int   -- ^ ruleId of receiver
  , cinfoId        :: Int         -- ^ internal channel ID
  , cinfoName      :: Name        -- ^ user supplied channel name
  , cinfoType      :: Type        -- ^ channel type
  , cinfoValueExpr :: Maybe Hash  -- ^ hash to channel value expression, may
                                  --   or may not be set
  , cinfoInit      :: Maybe (Const, ChannelDelay)  -- ^ chan initialization
  }
  deriving (Eq, Show)

-- | A StateHierarchy is a namespaced global state structure which is the
-- result of elaborating an 'Atom' monad computation.
data StateHierarchy
  = StateHierarchy Name [StateHierarchy]  -- ^ A namespaced hierarchy
  | StateVariable  Name Const             -- ^ A state variable with name and
                                          --   initial value
  | StateArray     Name [Const]           -- ^ A state array with name and list
                                          --   of initial values
  | StateChannel   Name Type              -- ^ A channel with name and channel
                                          --   value type
  deriving (Show)


-- | Given a hash for the parent Atom's enable expression and an 'AtomDB',
-- produce a list of 'Rule's in context of a `UeState` expression sharing
-- cache.
elaborateRules :: Hash -> AtomDB -> UeState [Rule]
elaborateRules parentEnable atom =
      if isRule then do r  <- rule
                        rs <- rules
                        return (r : rs)
                 else rules
  where
    -- Are there either assignments, actions, or writeChannels to be done?
    -- This check has the effect that atoms used as trivial outer shells
    -- around other immediate atoms are not translated into rules.
    isRule = not $ null (atomAssigns atom)
                     && null (atomActions atom)
                     && null (atomChanWrite atom)

    -- combine the parent enable and the child enable conditions
    enable :: UeState Hash
    enable = do
      st <- S.get
      let (h,st') = newUE (uand (recoverUE st parentEnable)
                                (recoverUE st (atomEnable atom)))
                           st
      S.put st'
      return h

    -- *don't* combine the parent enableNH and the child enableNH conditions
    enableNH :: UeState Hash
    enableNH = return (atomEnableNH atom)

    -- creat a 'Rule' from the 'AtomDB' and enable condition(s)
    rule :: UeState Rule
    rule = do
      h <- enable
      h' <- enableNH
      assigns <- S.foldM (\prs pr -> do pr' <- enableAssign pr
                                        return $ pr' : prs) []
                         (atomAssigns atom)
      return Rule
        { ruleId         = atomId   atom
        , ruleName       = atomName atom
        , ruleEnable     = h
        , ruleEnableNH   = h'
        , ruleAssigns    = assigns
        , ruleActions    = atomActions atom
        , rulePeriod     = atomPeriod  atom
        , rulePhase      = atomPhase   atom
        , ruleChanWrite  = atomChanWrite atom
        , ruleChanRead   = atomChanRead atom
        , ruleChanInit   = atomChanInit atom
        }

    assert :: (Name, Hash) -> UeState Rule
    assert (name, u) = do
      h <- enable
      h' <- enableNH
      return Assert
        { ruleName      = name
        , ruleEnable    = h
        , ruleEnableNH  = h'
        , ruleAssert    = u
        }

    cover :: (Name, Hash) -> UeState Rule
    cover (name, u) = do
      h <- enable
      h' <- enableNH
      return Cover
        { ruleName      = name
        , ruleEnable    = h
        , ruleEnableNH  = h'
        , ruleCover     = u
        }

    -- essentially maps 'ellaborateRules' over the asserts, covers, and
    -- subatoms in the given 'AtomDB'
    rules :: UeState [Rule]
    rules = do
      asserts <- S.foldM (\rs e -> do r <- assert e
                                      return (r:rs)
                         ) [] (atomAsserts atom)
      covers  <- S.foldM (\rs e -> do r <- cover e
                                      return (r:rs)
                         ) [] (atomCovers atom)
      rules'  <- S.foldM (\rs db -> do en <- enable
                                       r <- elaborateRules en db
                                       return (r:rs)
                         ) [] (atomSubs atom)
      return $ asserts ++ covers ++ concat rules'

    -- push the enable condition into each assignment. In the code generator
    -- this results in assignments like @uint64_t __6 = __0 ? __5 : __3;@
    -- where @__0@ is the 'enable' condition.
    enableAssign :: (MUV, Hash) -> UeState (MUV, Hash)
    enableAssign (uv', ue') = do
      e   <- enable
      enh <- enableNH
      h   <- maybeUpdate (MUVRef uv')  -- insert variable into the UE map
      st  <- S.get
      -- conjoin the regular enable condition and the non-inherited one,
      -- creating a new UE in the process
      let andes = uand (recoverUE st e) (recoverUE st enh)
          (e', st') = newUE andes st
      S.put st'
      let muxe      = umux (recoverUE st' e') (recoverUE st' ue') (recoverUE st' h)
          (h',st'') = newUE muxe st'
      S.put st''
      return (uv', h')

-- | Renormalize 'Rule' IDs starting at the given 'Int'.
reIdRules :: Int -> [Rule] -> [Rule]
reIdRules _ [] = []
reIdRules i (a:b) = case a of
  Rule{} -> a { ruleId = i } : reIdRules (i + 1) b
  _      -> a                : reIdRules  i      b

-- | Get a list of all channels written to in the given list of rules.
getChannels :: [Rule] -> Map Int ChanInfo
getChannels rs = Map.unionsWith mergeInfo (map getChannels' rs)
  where getChannels' :: Rule -> Map Int ChanInfo
        getChannels' r@Rule{} =
          -- TODO: fwrite and fread could be refactored in more concise way
          let fwrite :: (ChanInput, Hash, ChannelDelay) -> (Int, ChanInfo)
              fwrite (c, h, _) = ( chanID c
                                 , ChanInfo
                                     { cinfoSrc       = Just (ruleId r)
                                     , cinfoRecv      = Nothing
                                     , cinfoId        = chanID c
                                     , cinfoName      = chanName c
                                     , cinfoType      = chanType c
                                     , cinfoValueExpr = Just h
                                     , cinfoInit      = Nothing
                                     }
                                 )
              fread :: ChanOutput -> (Int, ChanInfo)
              fread c = ( chanID c
                        , ChanInfo
                            { cinfoSrc       = Nothing
                            , cinfoRecv      = Just (ruleId r)
                            , cinfoId        = chanID c
                            , cinfoName      = chanName c
                            , cinfoType      = chanType c
                            , cinfoValueExpr = Nothing
                            , cinfoInit      = Nothing
                            }
                        )
              finit :: (ChanInput, Const, ChannelDelay) -> (Int, ChanInfo)
              finit (c, v, d) = ( chanID c
                                 , ChanInfo
                                     { cinfoSrc       = Just (ruleId r)
                                     , cinfoRecv      = Nothing
                                     , cinfoId        = chanID c
                                     , cinfoName      = chanName c
                                     , cinfoType      = chanType c
                                     , cinfoValueExpr = Nothing
                                     , cinfoInit      = Just (v, d)
                                     }
                                 )
              m = Map.fromList (map fwrite (ruleChanWrite r)
                             ++ map fread (ruleChanRead r)
                             ++ map finit (ruleChanInit r))
          in m
        getChannels' _ = Map.empty  -- asserts and coverage statements have no channels

        -- Merge two channel info records, in particular this unions the
        -- `cinfoSrc` fields and also the `cinfoRecv` fields.
        mergeInfo :: ChanInfo -> ChanInfo -> ChanInfo
        mergeInfo c1 c2 =
          if (cinfoId c1 == cinfoId c2) &&      -- check invariant
             (cinfoName c1 == cinfoName c2) &&
             (cinfoType c1 == cinfoType c2) &&
             (cinfoValueExpr c1 == cinfoValueExpr c2 ||  -- either equal or
               isNothing (cinfoValueExpr c1) ||          -- one is a Nothing
               isNothing (cinfoValueExpr c2)) &&
             (cinfoInit c1 == cinfoInit c2 ||  -- either equal or
               isNothing (cinfoInit c1) ||     -- one is a Nothing
               isNothing (cinfoInit c2))
             then c1 { cinfoSrc = muxMaybe (cinfoSrc c1) (cinfoSrc c2)
                     , cinfoRecv = muxMaybe (cinfoRecv c1) (cinfoRecv c2)
                     , cinfoValueExpr = muxMaybe (cinfoValueExpr c1)
                                                 (cinfoValueExpr c2)
                     , cinfoInit = muxMaybe (cinfoInit c1) (cinfoInit c2)
                     }
             else error $ "Elaboration: getChannels: mismatch occured"
                       ++ "\n" ++ show c1
                       ++ "\n" ++ show c2

-- | Evaluate the computation carried by the given atom and return an 'AtomDB'
--   value, the intermediate representation for atoms at this level.
buildAtom
  :: CompCtx      -- ^ compiler context to start with
  -> UeMap        -- ^ untyped expression map to start with
  -> Global       -- ^ global data to start with
  -> Name         -- ^ top-level name of the atom design
  -> Atom a       -- ^ atom to evaluate
  -> ((a, CompNotes), AtomSt)  -- ^ atom return value, underlying final
                               -- evaluation state, and emitted warnings
buildAtom ctx st g name at =
  let (h,st') = newUE (ubool True) st
      initAtst = (st', ( g { gRuleId = gRuleId g + 1 }
                     , AtomDB
                         { atomId        = gRuleId g
                         , atomName      = name
                         , atomNames     = []
                         , atomEnable    = h
                         , atomEnableNH  = h
                         , atomSubs      = []
                         , atomPeriod    = gPeriod g
                         , atomPhase     = gPhase  g
                         , atomAssigns   = []
                         , atomActions   = []
                         , atomAsserts   = []
                         , atomCovers    = []
                         , atomChanWrite = []
                         , atomChanRead  = []
                         , atomChanInit  = []
                         }
                       )
                 )
  in runAtom ctx initAtst at

-- | Atom State type.
type AtomSt = (UeMap, (Global, AtomDB))
-- | Compiler Warnings.
type CompNotes = [String]
-- | Compiler Context, used to switch certain operations depending on the
--   compiler backend, e.g. switch from "scheduled periodicity" to "clocked
--   periodicity".
data CompCtx = CompCtx {
    -- ^ periodicity type to compile with; True = clocked periodicty, False =
    --   scheduled periodicity (only applicable to, and the default for, the C
    --   code backend).
    cctxPeriodicity :: Bool
  }

-- | The default C code backend compilation context; scheduled periodicity is
-- enabled.
defCCtx :: CompCtx
defCCtx = CompCtx { cctxPeriodicity = False }

-- | The default Sally Model backend compilation context; clocked periodicity
-- is enabled.
defSCtx :: CompCtx
defSCtx = CompCtx { cctxPeriodicity = True }

-- | The Atom monad is a state monad over the cache and intermediate
--   representation data needed to specifiy a guarded atomic action.
newtype Atom a = Atom { unAtom :: ReaderT CompCtx
                                          (WriterT CompNotes
                                                   (StateT AtomSt Id)) a }
  deriving (Applicative, Functor, Monad)

-- | Witness for the isomorphism between the newtype 'Atom' and the 'StateT'
-- underneath.
isoS :: Iso (ReaderT CompCtx (WriterT CompNotes (StateT AtomSt Id))) Atom
isoS = Iso Atom unAtom

-- | To get the non-unary type-class constraints we have to do a little work
instance StateM Atom AtomSt where
  get = derive_get isoS
  set = derive_set isoS

instance ReaderM Atom CompCtx where
  ask = derive_ask isoS

instance WriterM Atom CompNotes where
  put = derive_put isoS

-- | Run the state computation starting from the given initial 'AtomSt'.
runAtom :: CompCtx -> AtomSt -> Atom a -> ((a, CompNotes), AtomSt)
runAtom ctx st = runId           -- ((a, i1), i2)
               . runStateT st    -- IdT ((a, i1), i2)
               . runWriterT      -- StateT i2 IdT (a, i1)
               . runReaderT ctx  -- WriterT i1 (StateT i2 IdT) a
               . unAtom          -- ReaderT i0 (WriterT i1 (StateT i2 IdT)) a

-- | Given a top level name and design, elaborates design and returns a design
-- database.
--
-- XXX elaborate is a bit hacky since we're threading state through this
-- function, but I don't want to go change all the UeState monads to UeStateT
-- monads.
--
elaborate :: CompCtx -> UeMap -> Name -> Atom ()
          -> IO (Maybe ( UeMap
                       , (  StateHierarchy, [Rule], [ChanInfo], [Name], [Name]
                         , [(Name, Type)])
                       ))
elaborate ctx st name atom = do
      -- buildAtom runs the state computation contained by the atom, at the
      -- top-level here the atom result value is discarded
  let ((_, nts), atst) = buildAtom ctx st initialGlobal name atom
      (st0, (g, atomDB)) = atst
      (h, st1)        = newUE (ubool True) st0
      (getRules, st2) = S.runState (elaborateRules h atomDB) st1
      rules           = reIdRules 0 (reverse getRules)
      -- channel source and dest are numbered based on 'ruleId's in 'rules'
      channels        = Map.elems (getChannels rules)
      coverageNames   = [ name' | Cover  name' _ _ _ <- rules ]
      assertionNames  = [ name' | Assert name' _ _ _ <- rules ]
      probeNames      = [ (n, typeOf a st2) | (n, a) <- gProbes g ]
  -- emit warnings
  mapM_ (\m -> putStrLn ("WARNING: " ++ m)) (reverse nts)
  if null rules
    then do
      putStrLn "ERROR: Design contains no rules.  Nothing to do."
      return Nothing
    else do
      mapM_ (checkEnable st2) rules
      oks <- mapM checkAssignConflicts rules
      return $ if and oks
                 then Just ( st2
                           , ( trimState . StateHierarchy name $ gState g
                             , rules
                             , channels
                             , assertionNames
                             , coverageNames
                             , probeNames
                             )
                           )
                 else Nothing

-- | Remove namespaces in a 'StateHierarchy' that have no state in them.
trimState :: StateHierarchy -> StateHierarchy
trimState a = case a of
    StateHierarchy name items ->
      StateHierarchy name (filter f . map trimState $ items)
    a' -> a'
  where
    f (StateHierarchy _ []) = False
    f _ = True

-- | Check if state hierarchy is empty
isHierarchyEmpty :: StateHierarchy -> Bool
isHierarchyEmpty h = case h of
  StateHierarchy _ []  -> True
  StateHierarchy _ i   -> all isHierarchyEmpty i
  StateVariable  _ _   -> False
  StateArray     _ _   -> False
  StateChannel   _ _   -> False

-- | Checks that a rule will not be trivially disabled.
checkEnable :: UeMap -> Rule -> IO ()
checkEnable st rule
  | let f = (fst $ newUE (ubool False) st) in
    ruleEnable rule == f || ruleEnableNH rule == f
    = putStrLn $ "WARNING: Rule will never execute: " ++ show rule
  | otherwise = return ()

-- | Check that a variable is assigned more than once in a rule.  Will
-- eventually be replaced consistent assignment checking.
checkAssignConflicts :: Rule -> IO Bool
checkAssignConflicts rule@Rule{} =
  if length vars /= length vars'
    then do
      putStrLn $ "ERROR: Rule "
                   ++ show rule
                   ++ " contains multiple assignments to the same variable(s)."
      return False
    else
      return True
  where
  vars = map fst (ruleAssigns rule)
  vars' = nub vars
checkAssignConflicts _ = return True

-- | Generic local variable declaration.
var :: Expr a => Name -> a -> Atom (V a)
var name init' = do
  name' <- addName name
  (st, (g, atom)) <- get
  let uv' = UV (gVarId g) name' c
      c = constant init'
  set (st, ( g { gVarId = gVarId g + 1
               , gState = gState g ++ [StateVariable name c]
               }
           , atom
           )
      )
  return $ V uv'

-- | Generic external variable declaration.
var' :: Name -> Type -> V a
var' name t = V $ UVExtern name t

-- | Generic array declaration.
array :: Expr a => Name -> [a] -> Atom (A a)
array name [] = error $ "ERROR: arrays can not be empty: " ++ name
array name init' = do
  name' <- addName name
  (st, (g, atom)) <- get
  let ua = UA (gArrayId g) name' c
      c = map constant init'
  set (st, ( g { gArrayId = gArrayId g + 1
               , gState = gState g ++ [StateArray name c]
               }
           , atom
           )
      )
  return $ A ua

-- | Generic external array declaration.
array' :: Name -> Type -> A a
array' name t = A $ UAExtern  name t

-- | Add a name to the AtomDB and check that it is unique, throws an exception
-- if not.
--
-- Note: the name returned is prefixed with the state hierarchy selector.
addName :: Name -> Atom Name
addName name = do
  (st, (g, atom)) <- get
  checkName name
  if name `elem` atomNames atom
    then error $ unwords [ "ERROR: Name \"" ++ name ++ "\" not unique in"
                         , show atom ++ "." ]
    else do
      set (st, (g, atom { atomNames = name : atomNames atom }))
      return $ atomName atom ++ "." ++ name

-- still accepts some malformed names, like "_.." or "_]["
checkName :: Name -> Atom ()
checkName name =
  if (\ x -> isAlpha x || x == '_') (head name) &&
      all (\ x -> isAlphaNum x || x `elem` "._[]") (tail name)
    then return ()
    else error $ "ERROR: Name \"" ++ name ++ "\" is not a valid identifier."

-- | All the variables that directly and indirectly control the value of an expression.
allUVs :: UeMap -> [Rule] -> Hash -> [MUV]
allUVs st rules ue' = fixedpoint next $ nearestUVs ue' st
  where
  assigns = concat [ ruleAssigns r | r@Rule{} <- rules ]
  previousUVs :: MUV -> [MUV]
  previousUVs u = concat [ nearestUVs ue_ st | (uv', ue_) <- assigns, u == uv' ]
  next :: [MUV] -> [MUV]
  next uvs = sort $ nub $ uvs ++ concatMap previousUVs uvs

-- | Apply the function until a fixedpoint is found. Why is this not in
-- Prelude?
fixedpoint :: Eq a => (a -> a) -> a -> a
fixedpoint f a | a == f a  = a
               | otherwise = fixedpoint f $ f a

-- | All primary expressions used in a rule.
allUEs :: Rule -> [Hash]
allUEs rule = ruleEnable rule : ruleEnableNH rule : ues
  where
  index :: MUV -> [Hash]
  index (MUVArray _ ue') = [ue']
  index _ = []
  ues = case rule of
    Rule{} ->
         concat [ ue' : index uv' | (uv', ue') <- ruleAssigns rule ]
      ++ concatMap snd (ruleActions rule)
      ++ map (\(_, h, _) -> h) (ruleChanWrite rule)
    Assert _ _ _ a       -> [a]
    Cover  _ _ _ a       -> [a]

-- | Left biased combination of maybe values. `muxMaybe` has the property that
-- if one of the two inputs is a `Just`, then the output will also be.
muxMaybe :: Maybe a -> Maybe a -> Maybe a
muxMaybe x y = if isJust x then x
                           else y
