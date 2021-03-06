module Main where

import Data.List

import Language.LIMA
import Language.LIMA.C
import Language.Sally

import WBS (wbs)

main :: IO ()
main = do
  putStrLn "Compiling WBS to C... (wbs.{c,h})"
  compileWBSToC

  putStrLn "Compiling WBS to Sally... (wbs.mcmt)"
  -- TODO: specifying 'hybridMFA' below leads to an explosion in model
  -- generation
  let sallyCfg = defaultCfg { cfgMFA = NoFaults }
  compileToSally "wbs" sallyCfg "wbs.mcmt" wbs Nothing

  putStrLn "Done."


-- C Code Generator ------------------------------------------------------

-- | Invoke the LIMA compiler, generating 'wbs.{c,h}'
-- Also print out info on the generated schedule.
compileWBSToC :: IO ()
compileWBSToC = do
  res <- compile "wbs" cfg wbs
  putStrLn $ reportSchedule (compSchedule res)
  where
    cfg = defaults { cCode = prePostCode
                   , hCode = prePostH
                   }

-- | Custom pre-post code for generated C
prePostCode :: [Name] -> [Name] -> [(Name, Type)] -> (String, String)
prePostCode assertNames _covNames _probeNames =
  ( unlines [ "#include <stdio.h>"
            , "#include <unistd.h>"
            , ""
            , "static char* assert_names[" ++ show (length assertNames) ++ "] = "
              ++ "{" ++ intercalate "," (map (\n -> "\"" ++ n ++ "\"")  assertNames) ++ "};"
            , ""
            , "void assert(int id, bool c, int64_t clk) {"
            , "  if (!c) {"
            , "    printf(\"assertion %s failed at time %lld\\n\", assert_names[id], clk);"
            , "  }"
            , "}"
            , ""
            , "// ---- BEGIN of source automatically generated by LIMA ----"
            ]
  , unlines [ "// ---- END of source automatically generated by LIMA ----"
            , ""
            , "int main(int argc, char **argv) {"
            , "  while(1) { wbs(); usleep(500); }"
            , "}"
            ]
  )

-- | Custom pre-post header for generated C
prePostH :: [Name] -> [Name] -> [(Name, Type)] -> (String, String)
prePostH assertNames _covNames _probeNames =
  ( "void assert(int, bool, int64_t);"
  , ""
  )
