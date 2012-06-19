{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  lp2yices
-- Copyright   :  (c) Masahiro Sakai 2011
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-----------------------------------------------------------------------------
module Main where

import Data.Ord
import Data.List
import Data.Ratio
import qualified Data.Set as Set
import qualified Data.Map as Map
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO
import Text.Printf
import qualified Text.LPFile as LP

type Var = String
type Env = Map.Map LP.Var Var

concatS :: [ShowS] -> ShowS
concatS = foldr (.) id
 
unlinesS :: [ShowS] -> ShowS
unlinesS = concatS . map (. showChar '\n')

list :: [ShowS] -> ShowS
list xs = showParen True $ concatS (intersperse (showChar ' ') xs)

and' :: [ShowS] -> ShowS
and' [] = showString "true"
and' [x] = x
and' xs = list (showString "and" : xs)

or' :: [ShowS] -> ShowS
or' [] = showString "false"
or' [x] = x
or' xs = list (showString "or" : xs)

not' :: ShowS -> ShowS
not' x = list [showString "not", x]

expr :: Env -> LP.Expr -> ShowS
expr env e =
  case e of
    [] -> showChar '0'
    _ -> list (showChar '+' : map f e)
  where
    f (LP.Term c []) = num c
    f (LP.Term c vs) =
      case xs of
        [] -> showChar '1'
        [x] -> x
        _ -> list (showChar '*' : xs)
      where
        xs = [num c | c /= 1] ++ [showString (env Map.! v) | v <- vs]

num :: Rational -> ShowS
num r
  | denominator r == 1 = shows (numerator r)
  | otherwise = shows (numerator r) . showChar '/' . shows (denominator r)

rel :: Bool -> LP.RelOp -> ShowS -> ShowS -> ShowS
rel True LP.Eql x y = and' [rel False LP.Le x y, rel False LP.Ge x y]
rel _ LP.Eql x y = list [showString "=", x, y]
rel _ LP.Le x y = list [showString "<=", x, y]
rel _ LP.Ge x y = list [showString ">=", x, y]

assert :: ShowS -> ShowS
assert x = list [showString "assert", x]

constraint :: Bool -> Env -> LP.Constraint -> ShowS
constraint q env (_, g, (e, op, b)) =
  case g of 
    Nothing -> c
    Just (var,val) ->
      list [ showString "=>"
           , rel q LP.Eql (expr env [LP.Term 1 [var]]) (num val)
           , c
           ]
  where
    c = rel q op (expr env e) (num b)

conditions :: Bool -> Env -> LP.LP -> [ShowS]
conditions q env lp = bnds ++ bins ++ cs ++ ss
  where
    vs = LP.variables lp
    bins = do
      v <- Set.toList (LP.binaryVariables lp)
      let v2 = env Map.! v
      return $ list [showString "or", rel q LP.Eql (showString v2) (showChar '0'), rel q LP.Eql (showString v2) (showChar '1')]
    bnds = map bnd (Set.toList vs)
    bnd v =
      if v `Set.member` (LP.semiContinuousVariables lp)
       then or' [list [showString "=", showString v2, num 0], and' (s1 ++ s2)]
       else and' (s1 ++ s2)
      where
        v2 = env Map.! v
        (lb,ub) = LP.getBounds lp v
        s1 = case lb of
               LP.NegInf -> []
               LP.PosInf -> [showString "false"]
               LP.Finite x -> [list [showString "<=", num x, showString v2]]
        s2 = case ub of
               LP.NegInf -> [showString "false"]
               LP.PosInf -> []
               LP.Finite x -> [list [showString "<=", showString v2, num x]]
    cs = map (constraint q env) (LP.constraints lp)
    ss = concatMap sos (LP.sos lp)
    sos (_, typ, xs) = do
      (x1,x2) <- case typ of
                    LP.S1 -> pairs $ map fst xs
                    LP.S2 -> nonAdjacentPairs $ map fst $ sortBy (comparing snd) $ xs
      return $ not' $ and' [list [showString "/=", showString (env Map.! v), showChar '0']  | v<-[x1,x2]]

pairs :: [a] -> [(a,a)]
pairs [] = []
pairs (x:xs) = [(x,x2) | x2 <- xs] ++ pairs xs

nonAdjacentPairs :: [a] -> [(a,a)]
nonAdjacentPairs (x1:x2:xs) = [(x1,x3) | x3 <- xs] ++ nonAdjacentPairs (x2:xs)
nonAdjacentPairs _ = []

lp2ys :: LP.LP -> Bool -> Bool -> ShowS
lp2ys lp optimize check =
  unlinesS $ defs ++ map assert (conditions False env lp)
             ++ [ optimalityDef ]
             ++ [ assert (showString "optimality") | optimize ]
             ++ [ list [showString "set-evidence!", showString "true"] | check ]
             ++ [ list [showString "check"] | check ]
  where
    vs = LP.variables lp
    real_vs = vs `Set.difference` int_vs
    int_vs = LP.integerVariables lp `Set.union` LP.binaryVariables lp
    ts = [(v, "real")| v <- Set.toList real_vs] ++ [(v, "int") | v <- Set.toList int_vs]
    obj = snd (LP.objectiveFunction lp)
    env = Map.fromList [(v, encode v) | v <- Set.toList vs]
    -- Note that identifiers of LPFile does not contain '-'.
    -- So that there are no name crash.
    env2 = Map.fromList [(v, encode v ++ "-2") | v <- Set.toList vs]

    defs = do
      (v,t) <- ts
      let v2 = env Map.! v
      return $ showString $ printf "(define %s::%s) ; %s"  v2 t v

    optimalityDef = list [showString "define", showString "optimality::bool", optimality]

    optimality = list [showString "forall", decl, body]
      where
        decl = list [showString $ printf "%s::%s" (env2 Map.! v) t | (v,t) <- ts]
        body = list [showString "=>"
                    , and' (conditions True env2 lp)
                    , list [ showString $ if LP.dir lp == LP.OptMin then "<=" else ">="
                           , expr env obj, expr env2 obj
                           ]
                    ]

encode :: String -> String
encode s = concatMap f s
  where
    -- Note that '[', ']', '\\' does not appear in identifiers of LP file.
    f '(' = "["
    f ')' = "]"
    f c | c `elem` "/\";" = printf "\\x%02d" (fromEnum c :: Int)
    f c = [c]

data Flag
    = Help
    | Optimize
    | NoCheck
    deriving Eq

options :: [OptDescr Flag]
options =
    [ Option ['h'] ["help"]  (NoArg Help)       "show help"
    , Option [] ["optimize"] (NoArg Optimize)   "output optimiality condition which uses quantifiers"
    , Option [] ["no-check"] (NoArg NoCheck)    "do not output \"(check)\""
    ]


main :: IO ()
main = do
  args <- getArgs
  case getOpt Permute options args of
    (o,_,[])
      | Help `elem` o    -> putStrLn (usageInfo header options)
    (o,[fname],[]) -> do
      ret <- if fname == "-"
             then fmap (LP.parseString "-") getContents
             else LP.parseFile fname
      case ret of
        Right lp -> putStrLn $ lp2ys lp (Optimize `elem` o) (not (NoCheck `elem` o)) ""
        Left err -> hPrint stderr err >> exitFailure
    (_,_,errs) ->
        hPutStrLn stderr $ concat errs ++ usageInfo header options

header :: String
header = "Usage: lp2yice [file.lp|-]"

testFile :: FilePath -> IO ()
testFile fname = do
  result <- LP.parseFile fname
  case result of
    Right lp -> putStrLn $ lp2ys lp True True ""
    Left err -> hPrint stderr err

test :: IO ()
test = putStrLn $ lp2ys testdata True True ""

testdata :: LP.LP
Right testdata = LP.parseString "test" $ unlines
  [ "Maximize"
  , " obj: x1 + 2 x2 + 3 x3 + x4"
  , "Subject To"
  , " c1: - x1 + x2 + x3 + 10 x4 <= 20"
  , " c2: x1 - 3 x2 + x3 <= 30"
  , " c3: x2 - 3.5 x4 = 0"
  , "Bounds"
  , " 0 <= x1 <= 40"
  , " 2 <= x4 <= 3"
  , "General"
  , " x4"
  , "End"
  ]
