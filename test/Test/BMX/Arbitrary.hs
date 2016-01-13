{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Test.BMX.Arbitrary where

import           Data.Char (isAlpha)
import           Data.Data
import           Data.Generics.Aliases
import           Data.Generics.Schemes
import           Data.List (zipWith)
import           Data.Text (Text)
import qualified Data.Text as T
import           Test.QuickCheck
import           Test.QuickCheck.Instances ()

import           BMX.Data
import           BMX.Lexer

import           P

--------------------------------------------------------------------------------
-- AST / parser generators

instance Arbitrary Program where
  -- Adjacent ContentStmt clauses need to get concatenated.
  -- Do this recursively across all Program fragments in the tree via syb
  arbitrary = everywhere (mkT merge) . Program <$> smallList arbitrary
  shrink (Program sts) = everywhere (mkT merge) . Program <$> shrinkList shrink sts

instance Arbitrary Stmt where
  arbitrary = oneof [
      Mustache <$> arbitrary <*> bareExpr
    , MustacheUnescaped <$> arbitrary <*> bareExpr
    , Partial <$> arbitrary <*> bareExpr <*> expmay
    , PartialBlock <$> arbitrary <*> arbitrary <*> bareExpr <*> expmay <*> body
    , Block <$> arbitrary <*> arbitrary <*> bareExpr <*> bparams <*> body <*> inverseChain
    , InverseBlock <$> arbitrary <*> arbitrary <*> bareExpr <*> bparams <*> body <*> inverse
    , RawBlock <$> bareExpr <*> rawContent
    , ContentStmt <$> arbitrary `suchThat` validContent
    , CommentStmt <$> arbitrary <*> arbitrary `suchThat` validComment
    , Decorator <$> arbitrary <*> bareExpr
    , DecoratorBlock <$> arbitrary <*> arbitrary <*> bareExpr <*> body
    ]
    where
      bparams = oneof [pure Nothing, arbitrary]
      body = Program <$> smaller (smallList arbitrary)
      inverseChain = smaller $ sized goInverse
      goInverse 0 = pure Nothing
      goInverse n = oneof [pure Nothing, inverse, inverseChain' n]
      inverseChain' n = fmap Just $
        InverseChain <$> arbitrary <*> bareExpr <*> bparams <*> body <*> goInverse (n `div` 2)
      inverse = fmap Just $ Inverse <$> arbitrary <*> body
      expmay = elements [Just, const Nothing] <*> bareExpr
  shrink = \case
    ContentStmt t -> ContentStmt <$> filter validContent (shrink t)
    CommentStmt f t -> CommentStmt f <$> filter validComment (shrink t)
    RawBlock e _ -> RawBlock <$> shrink e <*> [T.empty]
    other -> genericShrink other

instance Arbitrary Expr where
  arbitrary = oneof [
      Lit <$> arbitrary
    , smaller bareExpr
    ]
  shrink = genericShrink

instance Arbitrary Literal where
  arbitrary = oneof [
      PathL <$> arbitrary
    , StringL <$> arbitrary `suchThat` validString
    , NumberL <$> arbitrary
    , BooleanL <$> arbitrary
    , pure UndefinedL
    , pure NullL
    ]
  shrink = \case
    StringL t -> StringL <$> filter validString (shrink t)
    other -> recursivelyShrink other

instance Arbitrary BlockParams where
  arbitrary = BlockParams <$> listOf1 name
    where
      -- A 'simple' name, i.e. an ID without path components
      name = PathL . Path . (:[]) . PathID <$> arbitrary `suchThat` validId
  shrink (BlockParams ps) = BlockParams <$> filter (not . null) (shrinkList shrink ps)

instance Arbitrary Path where
  arbitrary = do
    p <- elements [Path, DataPath]
    i <- PathID <$> arbitrary `suchThat` validId
    cs <- listOf pair
    pure $ p (i : mconcat cs)
    where
      ident = PathID <$> arbitrary `suchThat` validId
      sep = PathSep <$> elements ['.', '/']
      pair = do
        s <- sep
        i <- ident
        pure [s, i]
  shrink = \case
    Path ps -> Path <$> filter (not . null) (idsep ps)
    DataPath ps -> DataPath <$> filter (not . null) (idsep ps)
    where idsep = subsequenceCon [PathSep '_', PathID T.empty]

instance Arbitrary PathComponent where
  arbitrary = oneof [
      PathID <$> arbitrary `suchThat` validId
    , PathSep <$> elements ['.', '/']
    , PathSegment <$> arbitrary `suchThat` validComment
    ]
  shrink = \case
    PathID t -> PathID <$> filter validId (shrink t)
    _ -> []

instance Arbitrary Hash where
  arbitrary = Hash <$> smallList arbitrary
  shrink (Hash hps) = Hash <$> shrinkList shrink hps

instance Arbitrary HashPair where
  arbitrary = HashPair <$> arbitrary `suchThat` validId <*> smaller arbitrary
  shrink (HashPair t e) = HashPair <$> filter validId (shrink t) <*> shrink e

instance Arbitrary Fmt where
  arbitrary = Fmt <$> arbitrary <*> arbitrary

instance Arbitrary Format where
  arbitrary = elements [Strip, Verbatim]

bareExpr :: Gen Expr
bareExpr = SExp <$> arbitrary <*> smaller (smallList arbitrary) <*> smaller arbitrary

smallList :: Gen a -> Gen [a]
smallList g = sized go
  where
    go 0 = pure []
    go n = (:) <$> g <*> go (n `div` 2)

smaller :: Gen a -> Gen a
smaller g = sized $ \s -> resize (s `div` 2) g

merge :: Program -> Program
merge (Program ps) = Program (go ps)
  where
    go (ContentStmt t1 : ContentStmt t2 : xs) = go (ContentStmt (t1 <> t2) : xs)
    go (x : xs) = x : go xs
    go [] = []

-- Remove each subsequence with the same constructors as ms from ts
subsequenceCon :: (Data a, Typeable a) => [a] -> [a] -> [[a]]
subsequenceCon = dropSubsequenceBy (\t1 t2 -> toConstr t1 == toConstr t2)

-- given a pred and a subsequence, remove it from the list in every possible way
dropSubsequenceBy :: (a -> a -> Bool) -> [a] -> [a] -> [[a]]
dropSubsequenceBy _ [] _ = []
dropSubsequenceBy pred ms ts = go [] ts
  where
    lms = length ms
    go _ [] = []
    go tsa tsb =
      let rest = case tsb of
            [] -> []
            (x:xs) -> go (tsa <> [x]) xs
      in if and (zipWith pred ms tsb) then (tsa <> drop lms tsb) : rest else rest

validSegId :: Text -> Bool
validSegId t = and [noEscape t, noNull t, T.takeEnd 1 t /= "\\"]
  where noEscape tt = and (fmap escaped (splits tt))
        splits = T.breakOnAll "]"
        escaped (m, _) = and [T.takeEnd 1 m == "\\", T.takeEnd 2 m /= "\\\\"]

rawContent :: Gen Text
rawContent = do
  ts <- sized $ \s -> resize (min s 5) arbitrary
  pure (renderProgram ts)

-- | Allow only escaped Mustache expressions
noMustaches :: Text -> Bool
noMustaches t = and (fmap escaped splits)
  where
    splits = T.breakOnAll "{{" t
    escaped (m, _) = and [T.takeEnd 1 m == "\\", T.takeEnd 2 m /= "\\\\"]

-- | Get out of here, NUL!
noNull :: Text -> Bool
noNull t = isNothing (T.find (== '\0') t)

-- | Anything is valid as Content except for unescaped Mustaches, NUL, and empty.
-- Can contain a '{', but not at the end (e.g. [Content "{", Open] -> "{{{", parse fail)
-- Also can't end in '\', accidental escape
validContent :: Text -> Bool
validContent t = and [
    t /= T.empty
  , noNull t
  , noMustaches t
  , T.last t /= '{'
  , T.last t /= '\\'
  , T.head t /= '}'
  ]

-- | Anything without NUL is a valid comment
validComment :: Text -> Bool
validComment = noNull

-- | Weaker comments (inside {{! }} blocks) can't have mustaches
validWeakComment :: Text -> Bool
validWeakComment t = and [noNull t, noMustaches t, noMustacheClose t, T.takeEnd 1 t /= "}"]
  where noMustacheClose = P.null . T.breakOnAll "}}"

-- | Generated ID can't contain Sep characters, conflicts w sep
-- also can't contain anything in the other keywords
-- can't start with a number, else number parser kicks in
validId t = and [
    T.all (\c -> and [validIdChar c, c /= '.', c /= '/']) t
  , t /= "as"
  , not (T.null t)
  , isAlpha (T.head t)
  ]

validString :: Text -> Bool
validString t = and $ noNull t : unescapedEnd : (fmap noescape splits)
  where
    splits = T.breakOnAll "\"" t
    noescape (s, _) = T.takeEnd 1 s /= "\\"
    unescapedEnd = T.takeEnd 1 t /= "\\"