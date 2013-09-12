{-# LANGUAGE ScopedTypeVariables, BangPatterns #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Algorithm.CAD
-- Copyright   :  (c) Masahiro Sakai 2012
-- License     :  BSD-style
-- 
-- Maintainer  :  masahiro.sakai@gmail.com
-- Stability   :  provisional
-- Portability :  non-portable (ScopedTypeVariables, BangPatterns)
--
-- References:
--
-- *  Christian Michaux and Adem Ozturk.
--    Quantifier Elimination following Muchnik
--    <https://math.umons.ac.be/preprints/src/Ozturk020411.pdf>
--
-- *  Arnab Bhattacharyya.
--    Something you should know about: Quantifier Elimination (Part I)
--    <http://cstheory.blogoverflow.com/2011/11/something-you-should-know-about-quantifier-elimination-part-i/>
-- 
-- *  Arnab Bhattacharyya.
--    Something you should know about: Quantifier Elimination (Part II)
--    <http://cstheory.blogoverflow.com/2012/02/something-you-should-know-about-quantifier-elimination-part-ii/>
--
-----------------------------------------------------------------------------
module Algorithm.CAD
  (
  -- * Basic data structures
    Point (..)
  , Cell (..)

  -- * Projection
  , project

  -- * Solving
  , solve
  , solve'

  -- * Model
  , Model
  , findSample
  , evalCell
  , evalPoint
  ) where

import Control.Exception
import Control.Monad.State
import Data.List
import Data.Maybe
import Data.Ord
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Text.Printf
import Text.PrettyPrint.HughesPJClass

import Data.ArithRel
import qualified Data.AlgebraicNumber.Real as AReal
import Data.DNF
import Data.Polynomial (Polynomial, UPolynomial, X (..), PrettyVar, PrettyCoeff)
import qualified Data.Polynomial as P
import qualified Data.Polynomial.GroebnerBasis as GB
import Data.Sign (Sign (..))
import qualified Data.Sign as Sign


import Debug.Trace

-- ---------------------------------------------------------------------------

data Point c = NegInf | RootOf (UPolynomial c) Int | PosInf
  deriving (Eq, Ord, Show)

data Cell c
  = Point (Point c)
  | Interval (Point c) (Point c)
  deriving (Eq, Ord, Show)

showCell :: (Num c, Ord c, PrettyCoeff c) => Cell c -> String
showCell (Point pt) = showPoint pt
showCell (Interval lb ub) = printf "(%s, %s)" (showPoint lb) (showPoint ub)

showPoint :: (Num c, Ord c, PrettyCoeff c) => Point c -> String
showPoint NegInf = "-inf"
showPoint PosInf = "+inf"
showPoint (RootOf p n) = "rootOf(" ++ prettyShow p ++ ", " ++ show n ++ ")"

-- ---------------------------------------------------------------------------

type SignConf c = [(Cell c, Map (UPolynomial c) Sign)]

emptySignConf :: SignConf c
emptySignConf =
  [ (Point NegInf, Map.empty)
  , (Interval NegInf PosInf, Map.empty)
  , (Point PosInf, Map.empty)
  ]

showSignConf :: forall c. (Num c, Ord c, PrettyCoeff c) => SignConf c -> [String]
showSignConf = f
  where
    f :: SignConf c -> [String]
    f = concatMap $ \(cell, m) -> showCell cell : g m

    g :: Map (UPolynomial c) Sign -> [String]
    g m =
      [printf "  %s: %s" (prettyShow p) (Sign.symbol s) | (p, s) <- Map.toList m]

-- ---------------------------------------------------------------------------

-- modified reminder
mr
  :: forall k. (Ord k, Show k, Num k, PrettyCoeff k)
  => UPolynomial k
  -> UPolynomial k
  -> (k, Integer, UPolynomial k)
mr p q
  | n >= m    = assert (P.constant (bm^(n-m+1)) * p == q * l + r && m > P.deg r) $ (bm, n-m+1, r)
  | otherwise = error "mr p q: not (deg p >= deg q)"
  where
    x = P.var X
    n = P.deg p
    m = P.deg q
    bm = P.lc P.grlex q
    (l,r) = f p n

    f :: UPolynomial k -> Integer -> (UPolynomial k, UPolynomial k)
    f p n
      | n==m =
          let l = P.constant an
              r = P.constant bm * p - P.constant an * q
          in assert (P.constant (bm^(n-m+1)) * p == q*l + r && m > P.deg r) $ (l, r)
      | otherwise =
          let p'     = (P.constant bm * p - P.constant an * x^(n-m) * q)
              (l',r) = f p' (n-1)
              l      = l' + P.constant (an*bm^(n-m)) * x^(n-m)
          in assert (n > P.deg p') $
             assert (P.constant (bm^(n-m+1)) * p == q*l + r && m > P.deg r) $ (l, r)
      where
        an = P.coeff (P.var X `P.mpow` n) p

test_mr_1 :: (Coeff Int, Integer, UPolynomial (Coeff Int))
test_mr_1 = mr (P.toUPolynomialOf p 3) (P.toUPolynomialOf q 3)
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    x = P.var 3
    p = a*x^(2::Int) + b*x + c
    q = 2*a*x + b

test_mr_2 :: (Coeff Int, Integer, UPolynomial (Coeff Int))
test_mr_2 = mr (P.toUPolynomialOf p 3) (P.toUPolynomialOf p 3)
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    x = P.var 3
    p = a*x^(2::Int) + b*x + c

-- ---------------------------------------------------------------------------

type Coeff v = Polynomial Rational v

type M v = StateT (Assumption v) []

runM :: M v a -> [(a, Assumption v)]
runM m = runStateT m emptyAssumption

assume :: (Ord v, Show v, PrettyVar v) => Polynomial Rational v -> [Sign] -> M v ()
assume p ss = do
  (m,gb) <- get
  p <- return $ P.reduce P.grevlex p gb
  if P.deg p <= 0
    then guard $ Sign.signOf (P.coeff P.mone p) `elem` ss
    else do
      let c   = P.lc P.grlex p
      (p,ss) <- return $ (P.mapCoeff (/c) p, [s `Sign.div` Sign.signOf c | s <- ss])
      let ss1 = Map.findWithDefault (Set.fromList [Neg, Zero, Pos]) p m
          ss2 = Set.intersection ss1 $ Set.fromList ss
      guard $ not $ Set.null ss2
      if ss2 == Set.singleton Zero
        then
          case propagateZeros (m, GB.basis P.grevlex (p : gb)) of
            Nothing -> mzero
            Just (m', gb') -> put (m', gb')
        else
          put (Map.insert p ss2 m, gb)

project
  :: forall v. (Ord v, Show v, PrettyVar v)
  => [(UPolynomial (Polynomial Rational v), [Sign])]
  -> [([(Polynomial Rational v, [Sign])], [Cell (Polynomial Rational v)])]
project cs = [ (assumption2cond gs, cells) | (cells, gs) <- result ]
  where
    result :: [([Cell (Polynomial Rational v)], Assumption v)]
    result = runM $ do
      forM_ cs $ \(p,ss) -> do
        when (1 > P.deg p) $ assume (P.coeff P.mone p) ss
      conf <- buildSignConf (map fst cs)
      -- normalizePoly前に次数が1以上で、normalizePoly結果の次数が0以下の時のための処理が必要なので注意
      cs' <- liftM catMaybes $ forM cs $ \(p,ss) -> do
        p' <- normalizePoly p
        if (1 > P.deg p')
          then assume (P.coeff P.mone p') ss >> return Nothing
          else return $ Just (p',ss)
      let satCells = [cell | (cell, m) <- conf, cell /= Point NegInf, cell /= Point PosInf, ok cs' m]
      guard $ not $ null satCells
      return satCells

    ok :: [(UPolynomial (Polynomial Rational v), [Sign])] -> Map (UPolynomial (Polynomial Rational v)) Sign -> Bool
    ok cs m = and [checkSign m p ss | (p,ss) <- cs]
      where
        checkSign m p ss = (m Map.! p) `elem` ss

buildSignConf
  :: (Ord v, Show v, PrettyVar v)
  => [UPolynomial (Polynomial Rational v)]
  -> M v (SignConf (Polynomial Rational v))
buildSignConf ps = do
  ps2 <- collectPolynomials (Set.fromList ps)
  -- normalizePoly後の多項式の次数でソートしておく必要があるので注意
  let ts = sortBy (comparing P.deg) (Set.toList ps2)
  foldM (flip refineSignConf) emptySignConf ts

collectPolynomials
  :: (Ord v, Show v, PrettyVar v)
  => Set (UPolynomial (Polynomial Rational v))
  -> M v (Set (UPolynomial (Polynomial Rational v)))
collectPolynomials ps = go Set.empty =<< f (Set.toList ps)
  where
    f ps = do
      ps' <- mapM normalizePoly ps
      return $ Set.fromList $ filter (\p -> P.deg p > 0) ps'

    go result ps | Set.null ps = return result
    go result ps = do
      let rs = [P.deriv p X | p <- Set.toList ps]
      rss <-
        forM [(p1,p2) | p1 <- Set.toList ps, p2 <- Set.toList ps ++ Set.toList result, p1 /= p2] $ \(p1,p2) -> do
          let d = P.deg p1
              e = P.deg p2
          return [r | (_,_,r) <- [mr p1 p2 | d >= e] ++ [mr p2 p1 | e >= d]]
      ps' <- f (concat (rs:rss))
      go (result `Set.union` ps) (ps' `Set.difference` result)

-- ゼロであるような高次の項を消した多項式を返す
normalizePoly
  :: forall v. (Ord v, Show v, PrettyVar v)
  => UPolynomial (Polynomial Rational v)
  -> M v (UPolynomial (Polynomial Rational v))
normalizePoly p = liftM P.fromTerms $ go $ sortBy (flip (comparing (P.deg . snd))) $ P.terms p
  where
    go [] = return []
    go xxs@((c,d):xs) =
      mplus
        (assume c [Pos, Neg] >> return xxs)
        (assume c [Zero] >> go xs)

refineSignConf
  :: forall v. (Show v, Ord v, PrettyVar v)
  => UPolynomial (Polynomial Rational v)
  -> SignConf (Polynomial Rational v) 
  -> M v (SignConf (Polynomial Rational v))
refineSignConf p conf = liftM (extendIntervals 0) $ mapM extendPoint conf
  where 
    extendPoint
      :: (Cell (Polynomial Rational v), Map (UPolynomial (Polynomial Rational v)) Sign)
      -> M v (Cell (Polynomial Rational v), Map (UPolynomial (Polynomial Rational v)) Sign)
    extendPoint (Point pt, m) = do
      s <- signAt pt m
      return (Point pt, Map.insert p s m)
    extendPoint x = return x
 
    extendIntervals
      :: Int
      -> [(Cell (Polynomial Rational v), Map (UPolynomial (Polynomial Rational v)) Sign)]
      -> [(Cell (Polynomial Rational v), Map (UPolynomial (Polynomial Rational v)) Sign)]
    extendIntervals !n (pt1@(Point _, m1) : (Interval lb ub, m) : pt2@(Point _, m2) : xs) =
      pt1 : ys ++ extendIntervals n2 (pt2 : xs)
      where
        s1 = m1 Map.! p
        s2 = m2 Map.! p
        n1 = if s1 == Zero then n+1 else n
        root = RootOf p n1
        (ys, n2)
           | s1 == s2   = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | s1 == Zero = ( [ (Interval lb ub, Map.insert p s2 m) ], n1 )
           | s2 == Zero = ( [ (Interval lb ub, Map.insert p s1 m) ], n1 )
           | otherwise  = ( [ (Interval lb root, Map.insert p s1   m)
                            , (Point root,       Map.insert p Zero m)
                            , (Interval root ub, Map.insert p s2   m)
                            ]
                          , n1 + 1
                          )
    extendIntervals _ xs = xs
 
    signAt :: Point (Polynomial Rational v) -> Map (UPolynomial (Polynomial Rational v)) Sign -> M v Sign
    signAt PosInf _ = signCoeff (P.lc P.grevlex p)
    signAt NegInf _ = do
      let (c,mm) = P.lt P.grevlex p
      if even (P.deg mm)
        then signCoeff c
        else liftM Sign.negate $ signCoeff c
    signAt (RootOf q _) m = do
      let (bm,k,r) = mr p q
      r <- normalizePoly r
      s1 <- if P.deg r > 0
            then return $ m Map.! r
            else signCoeff $ P.coeff P.mone r
      -- 場合分けを出来るだけ避ける
      if even k
        then return s1
        else do
          s2 <- signCoeff bm
          return $ s1 `Sign.div` Sign.pow s2 k

    signCoeff :: Polynomial Rational v -> M v Sign
    signCoeff c =
      msum [ assume c [s] >> return s
           | s <- [Neg, Zero, Pos]
           ]

-- ---------------------------------------------------------------------------

type Assumption v = (Map (Polynomial Rational v) (Set Sign), [Polynomial Rational v])

emptyAssumption :: Assumption v
emptyAssumption = (Map.empty, [])

propagateZeros :: Ord v => Assumption v -> Maybe (Assumption v)
propagateZeros (m, gb) = do
  let xs = [(P.reduce P.grevlex q gb, ss) | (q,ss) <- Map.toList m]
  xs <- flip filterM xs $ \(q,ss) -> do
    if P.deg q <= 0
      then do
        guard $ Sign.signOf (P.coeff P.mone q) `Set.member` ss
        return False
      else do
        return True
  let m' = Map.fromListWith Set.intersection xs
  guard $ and [not (Set.null ss) | (q,ss) <- Map.toList m']
  let (m0,m1) = Map.partition (Set.singleton Zero ==) m'
  if Map.null m0
    then return (m1, gb)
    else propagateZeros (m1, GB.basis P.grevlex (Map.keys m0 ++ gb))

assumption2cond :: Ord v => Assumption v -> [(Polynomial Rational v, [Sign])]
assumption2cond (m, gb) = [(p, Set.toList ss)  | (p, ss) <- Map.toList m] ++ [(p, [Zero]) | p <- gb]

-- ---------------------------------------------------------------------------

type Model v = Map v AReal.AReal

findSample :: Ord v => Model v -> Cell (Polynomial Rational v) -> Maybe AReal.AReal
findSample m cell =
  case evalCell m cell of
    Point (RootOf p n) -> 
      Just $ AReal.realRoots p !! n
    Interval NegInf PosInf ->
      Just $ 0
    Interval NegInf (RootOf p n) ->
      Just $ fromInteger $ floor   ((AReal.realRoots p !! n) - 1)
    Interval (RootOf p n) PosInf ->
      Just $ fromInteger $ ceiling ((AReal.realRoots p !! n) + 1)
    Interval (RootOf p1 n1) (RootOf p2 n2)
      | (pt1 < pt2) -> Just $ (pt1 + pt2) / 2
      | otherwise   -> Nothing
      where
        pt1 = AReal.realRoots p1 !! n1
        pt2 = AReal.realRoots p2 !! n2
    _ -> error $ "findSample: should not happen"

evalCell :: Ord v => Model v -> Cell (Polynomial Rational v) -> Cell Rational
evalCell m (Point pt)         = Point $ evalPoint m pt
evalCell m (Interval pt1 pt2) = Interval (evalPoint m pt1) (evalPoint m pt2)

evalPoint :: Ord v => Model v -> Point (Polynomial Rational v) -> Point Rational
evalPoint _ NegInf = NegInf
evalPoint _ PosInf = PosInf
evalPoint m (RootOf p n) = RootOf (AReal.minimalPolynomial a) (AReal.rootIndex a)
  where
    a = AReal.realRootsEx (P.mapCoeff (P.eval (m Map.!) . P.mapCoeff fromRational) p) !! n

-- ---------------------------------------------------------------------------

solve
  :: forall v. (Ord v, Show v, PrettyVar v)
  => Set v
  -> [(Rel (Polynomial Rational v))]
  -> Maybe (Model v)
solve vs cs0 = solve' vs (map f cs0)
  where
    f (Rel lhs op rhs) = (lhs - rhs, g op)
    g Le  = [Zero, Neg]
    g Ge  = [Zero, Pos]
    g Lt  = [Neg]
    g Gt  = [Pos]
    g Eql = [Zero]
    g NEq = [Pos,Neg]

solve'
  :: forall v. (Ord v, Show v, PrettyVar v)
  => Set v
  -> [(Polynomial Rational v, [Sign])]
  -> Maybe (Model v)
solve' vs0 cs0 = go (Set.toList vs0) cs0
  where
    go :: [v] -> [(Polynomial Rational v, [Sign])] -> Maybe (Model v)
    go [] cs =
      if and [Sign.signOf v `elem` ss | (p,ss) <- cs, let v = P.eval (\_ -> undefined) p]
      then Just Map.empty
      else Nothing
    go (v:vs) cs = listToMaybe $ do
      (cs2, cell:_) <- project [(P.toUPolynomialOf p v, ss) | (p,ss) <- cs]
      case go vs cs2 of
        Nothing -> mzero
        Just m -> do
          let Just val = findSample m cell
          seq val $ return $ Map.insert v val m

-- ---------------------------------------------------------------------------

showDNF :: (Ord v, Show v, PrettyVar v) => DNF (Polynomial Rational v, [Sign]) -> String
showDNF (DNF xss) = intercalate " | " [showConj xs | xs <- xss]
  where
    showConj xs = "(" ++ intercalate " & " [f p ss | (p,ss) <- xs] ++ ")"
    f p ss = prettyShow p ++ g ss
    g [Zero] = " = 0"
    g [Pos]  = " > 0"
    g [Neg]  = " < 0"
    g xs
      | Set.fromList xs == Set.fromList [Pos,Neg] = "/= 0"
      | Set.fromList xs == Set.fromList [Zero,Pos] = ">= 0"
      | Set.fromList xs == Set.fromList [Zero,Neg] = "<= 0"
      | otherwise = error "showDNF: should not happen"

dumpProjection
  :: (Ord v, Show v, PrettyVar v)
  => [([(Polynomial Rational v, [Sign])], [Cell (Polynomial Rational v)])]
  -> IO ()
dumpProjection xs =
  forM_ xs $ \(gs, cells) -> do
    putStrLn "============"
    forM_ gs $ \(p, ss) -> do
      putStrLn $ f p ss
    putStrLn " =>"
    forM_ cells $ \cell -> do
      putStrLn $ showCell cell
  where
    f p ss = prettyShow p ++ g ss
    g [Zero] = " = 0"
    g [Pos]  = " > 0"
    g [Neg]  = " < 0"
    g xs
      | Set.fromList xs == Set.fromList [Pos,Neg]  = "/= 0"
      | Set.fromList xs == Set.fromList [Zero,Pos] = ">= 0"
      | Set.fromList xs == Set.fromList [Zero,Neg] = "<= 0"
      | otherwise = error "showDNF: should not happen"

dumpSignConf
  :: forall v.
     (Ord v, PrettyVar v, Show v)
  => [(SignConf (Polynomial Rational v), Assumption v)]
  -> IO ()
dumpSignConf x = 
  forM_ x $ \(conf, as) -> do
    putStrLn "============"
    mapM_ putStrLn $ showSignConf conf
    forM_  (assumption2cond as) $ \(p, ss) ->
      printf "%s %s\n" (prettyShow p) (show ss)

-- ---------------------------------------------------------------------------

test1a :: IO ()
test1a = mapM_ putStrLn $ showSignConf conf
  where
    x = P.var X
    ps :: [UPolynomial (Polynomial Rational Int)]
    ps = [x + 1, -2*x + 3, x]
    [(conf, _)] = runM $ buildSignConf ps

test1b :: Bool
test1b = isJust $ solve vs cs
  where
    x = P.var X
    vs = Set.singleton X
    cs = [x + 1 .>. 0, -2*x + 3 .>. 0, x .>. 0]

test1c :: Bool
test1c = isJust $ do
  m <- solve' (Set.singleton X) cs
  guard $ and $ do
    (p, ss) <- cs
    let val = P.eval (m Map.!) (P.mapCoeff fromRational p)
    return $ Sign.signOf val `elem` ss
  where
    x = P.var X
    cs = [(x + 1, [Pos]), (-2*x + 3, [Pos]), (x, [Pos])]

test2a :: IO ()
test2a = mapM_ putStrLn $ showSignConf conf
  where
    x = P.var X
    ps :: [UPolynomial (Polynomial Rational Int)]
    ps = [x^(2::Int)]
    [(conf, _)] = runM $ buildSignConf ps

test2b :: Bool
test2b = isNothing $ solve vs cs
  where
    x = P.var X
    vs = Set.singleton X
    cs = [x^(2::Int) .<. 0]

test = and [test1b, test1c, test2b]

test_project :: DNF (Polynomial Rational Int, [Sign])
test_project = DNF $ map fst $ project [(p', [Zero])]
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    x = P.var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c
    p' = P.toUPolynomialOf p 3

test_project_print :: IO ()
test_project_print = putStrLn $ showDNF $ test_project

test_project_2 = project [(p, [Zero]), (x, [Pos])]
  where
    x = P.var X
    p :: UPolynomial (Polynomial Rational Int)
    p = x^(2::Int) + 4*x - 10

test_project_3_print =  dumpProjection $ project [(P.toUPolynomialOf p 0, [Neg])]
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    p :: Polynomial Rational Int
    p = a^(2::Int) + b^(2::Int) + c^(2::Int) - 1

test_solve = solve vs [p .<. 0]
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    vs = Set.fromList [0,1,2]
    p :: Polynomial Rational Int
    p = a^(2::Int) + b^(2::Int) + c^(2::Int) - 1

test_collectPolynomials
  :: [( Set (UPolynomial (Polynomial Rational Int))
      , Assumption Int
      )]
test_collectPolynomials = runM $ collectPolynomials (Set.singleton p')
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    x = P.var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c
    p' = P.toUPolynomialOf p 3

test_collectPolynomials_print :: IO ()
test_collectPolynomials_print = do
  forM_ test_collectPolynomials $ \(ps,g) -> do
    putStrLn "============"
    mapM_ (putStrLn . prettyShow) (Set.toList ps)
    forM_  (assumption2cond g) $ \(p, ss) ->
      printf "%s %s\n" (prettyShow p) (show ss)

test_buildSignConf :: [(SignConf (Polynomial Rational Int), Assumption Int)]
test_buildSignConf = runM $ buildSignConf [P.toUPolynomialOf p 3]
  where
    a = P.var 0
    b = P.var 1
    c = P.var 2
    x = P.var 3
    p :: Polynomial Rational Int
    p = a*x^(2::Int) + b*x + c

test_buildSignConf_print :: IO ()
test_buildSignConf_print = dumpSignConf test_buildSignConf

test_buildSignConf_2 :: [(SignConf (Polynomial Rational Int), Assumption Int)]
test_buildSignConf_2 = runM $ buildSignConf [P.toUPolynomialOf p 0 | p <- ps]
  where
    x = P.var 0
    ps :: [Polynomial Rational Int]
    ps = [x + 1, -2*x + 3, x]

test_buildSignConf_2_print :: IO ()
test_buildSignConf_2_print = dumpSignConf test_buildSignConf_2

test_buildSignConf_3 :: [(SignConf (Polynomial Rational Int), Assumption Int)]
test_buildSignConf_3 = runM $ buildSignConf [P.toUPolynomialOf p 0 | p <- ps]
  where
    x = P.var 0
    ps :: [Polynomial Rational Int]
    ps = [x, 2*x]

test_buildSignConf_3_print :: IO ()
test_buildSignConf_3_print = dumpSignConf test_buildSignConf_3

-- ---------------------------------------------------------------------------
