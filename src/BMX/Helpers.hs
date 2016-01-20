{-| The collection of builtin helpers, included in the default environment. -}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module BMX.Helpers where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Text (Text)
import qualified Data.Text as T

import           BMX.Data
import           BMX.Eval
import           BMX.Function

import           P

-- | The "noop" block helper. Renders the main block.
helper_noop :: (Applicative m, Monad m) => Helper m
helper_noop = BlockHelper $ \b _ -> liftBMX (eval b)

-- | The "if" block helper. Renders the main block if the argument is truthy.
-- Otherwise, it renders the inverse block.
helper_if :: (Applicative m, Monad m) => Helper m
helper_if = BlockHelper $ \thenp elsep -> do
  v <- value
  liftBMX $ if truthy v then eval thenp else eval elsep

-- | The "unless" block helper. The opposite of "if".
helper_unless :: (Applicative m, Monad m) => Helper m
helper_unless = BlockHelper $ \thenp elsep -> do
  v <- value
  liftBMX $ if truthy v then eval elsep else eval thenp

-- | The "with" block helper. Accept a Context as argument.
helper_with :: (Applicative m, Monad m) => Helper m
helper_with = BlockHelper $ \thenp elsep -> do
  ctx <- optional context
  liftBMX $ maybe
    (eval elsep)
    (\(ContextV c) -> withContext c (eval thenp))
    ctx

-- | The "log" helper. Writes every argument to the log in a single line.
helper_log :: (Applicative m, Monad m) => Helper m
helper_log = Helper $ do
  args <- many value
  liftBMX $ do
    logs (T.unwords $ fmap renderValue args)
    return (StringV "")

-- | The "lookup" helper. Takes a context and a string, and looks up a
-- value in a context. Returns @undefined@ when it doesn't exist.
helper_lookup :: (Applicative m, Monad m) => Helper m
helper_lookup = Helper $ do
  (ContextV ctx) <- context
  (StringV str) <- string
  liftBMX $ do
    mv <- withContext ctx (lookupValue (PathID str Nothing))
    return (fromMaybe UndefinedV mv)

-- | The "each" helper. Takes an iterable value (a context or a list),
-- and renders the main block for each item in the collection.
-- If the collection is empty, it renders the inverse block instead.
-- The special variables @first, @last, @key, @index, and this are registered
-- during the loop. These are as defined in Handlebars.
-- If block parameters are supplied, we also bind the first parameter to the
-- value in each loop, and the second parameter to the loop index.
helper_each :: (Applicative m, Monad m) => Helper m
helper_each = BlockHelper $ \thenp elsep -> do
  iter <- try list <|> context
  name <- optional param -- param: name for current item
  idx <- optional param -- param: name for current loop idx
  -- This is the worst, mostly because of special variables.
  let go = case iter of
        ContextV c -> fmap fold (sequence (eachMap c))
        ListV l -> fmap fold (sequence (eachList l))
        v -> err (TypeError "context or list" (renderValueType v))
      -- Separate iteration cases for context and list
      eachMap (Context c) = indices 0 (fmap stepKV (M.toList c))
      eachList l = indices 0 (fmap step l)
      -- Apply indices, first and last markers to each action
      indices 0 (k:ks@(_:_)) = index 0 (frst k) : indices 1 ks
      indices n (k:ks@(_:_)) = index n k : indices (n + 1) ks
      indices n (k:[]) = [index n (last k)]
      indices _ [] = []
      -- Register various special variables
      stepKV (k,v) = withData "key" (DValue (StringV k)) (step v)
      step v = withVariable "this" v . withName name v $ eval thenp
      index i k = withData "index" (DValue (IntV i)) . withName idx (IntV i) $ k
      frst = withData "first" (DValue (BoolV True))
      last = withData "last" (DValue (BoolV True))
      -- Register blockparams if they were supplied
      withName Nothing _ k = k
      withName (Just (Param n)) v k = withVariable n v k
  liftBMX $ if falsey iter then eval elsep else go

-- | The default collection of builtins.
builtinHelpers :: (Applicative m, Monad m) => Map Text (Helper m)
builtinHelpers = M.fromList [
    ("noop", helper_noop)
  , ("if", helper_if)
  , ("unless", helper_unless)
  , ("with", helper_with)
  , ("log", helper_log)
  , ("lookup", helper_lookup)
  , ("each", helper_each)
  ]

-- | The "inline" block decorator. Turns the block argument into a partial
-- with the name of the first argument.
decorator_inline :: (Applicative m, Monad m) => Decorator m
decorator_inline = BlockDecorator $ \block k -> do
  (StringV name) <- string
  liftBMX $ do
    let newPartial = Partial (eval block)
    withPartial name newPartial k

builtinDecorators :: (Applicative m, Monad m) => Map Text (Decorator m)
builtinDecorators = M.fromList [
    ("inline", decorator_inline)
  ]

-- FIX this also doesn't belong here
-- FIX pass context in?
defaultEvalState :: (Applicative m, Monad m) => EvalState m
defaultEvalState = EvalState {
    evalContext = [testContext]
  , evalData = M.empty
  , evalHelpers = builtinHelpers
  , evalPartials = M.insert "authorid" testPartial M.empty
  , evalDecorators = builtinDecorators
  }

-- FIX this must also go
testContext :: Context
testContext = Context $ M.fromList [
    ("title", StringV "My First Blog Post!")
  , ("author", ContextV . Context $ M.fromList [
                   ("id", IntV 47)
                 , ("name", StringV "Yehuda Katz")
                 ])
  , ("body", StringV "My first post. Wheeeee!")
  , ("html", StringV "<a href=\"google.com\">Cool Site</a>")
  , ("component", StringV "authorid")
  ]

-- FIX temporary test value
testPartial :: (Applicative m, Monad m) => Partial m
testPartial = Partial . eval $
  Template
    [ ContentStmt "The author's name is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "name" Nothing)) [] (Hash []))
    , ContentStmt " and their ID is "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "id" Nothing)) [] (Hash []))
    , ContentStmt " arg = "
    , Mustache (Fmt Verbatim Verbatim) (SExp (PathL (PathID "arg" Nothing)) [] (Hash []))
    ]
