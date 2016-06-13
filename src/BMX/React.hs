{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module BMX.React (
    renderReactFile
  , renderReact
  ) where

import qualified Data.Char as C
import           Data.Text (Text)
import qualified Data.Text as T

import           BMX.Data

import           P


type Scope = [[Text]]


renderReactFile :: Text -> Template -> Text
renderReactFile n t =
     "\"use strict\";\n"
  <> "\n"
  <> "var React = require('react');\n"
  <> "\n"
  <> "exports" <> renderJsArg n <> " = function(context, args, data) {\n"
       <> "  return " <> renderReact [["args"]] t <> ";\n"
       <> "};\n"

renderReact :: Scope -> Template -> Text
renderReact scope (Template ss) =
  foldMap (renderReactStmt scope) ss

renderReactTemplate :: Scope -> Template -> Text
renderReactTemplate scope (Template ss) =
  "[" <> (T.intercalate ", " . fmap (renderReactStmt scope)) ss <> "]"

renderReactStmt :: Scope -> Positioned Stmt -> Text
renderReactStmt scope (stmt :@ _) = case stmt of
  ContentStmt (t :@ _) ->
    "'" <> t <> "'"
  CommentStmt _ (comment :@ _) ->
    "/*" <> comment <> "*/"
  Mustache _ ((SExp (l :@ _) _ _) :@ _) ->
    renderReactLiteral scope l
  MustacheUnescaped (Fmt l r) (e :@ _) ->
    -- FIX Be nice not to have to create a span tag
    "React.createElement('span', {dangerouslySetInnerHTML: {__html: " <> renderReactExpr scope e <> "}})";
  Block _ _ e bp b i ->
    renderBlock scope e bp b i
  Inverse _ (p :@ _) ->
    -- FIX What happens to inverse?
    renderReactTemplate scope p
  InverseBlock _ _ e bp b i ->
    renderBlock scope e bp i b

  -- Treat this as a block too, although it lacks the lower formatting
  InverseChain _ e bp b i ->
    renderBlock scope e bp b i

  -- Special handler that resolves and inlines the partial
  PartialStmt (Fmt l r) e@(_ :@ el) ee h ->
    renderPartial scope e ee h (Template [] :@ el)

  -- Special handler that registers @partial-block, and fails over if partial not found
  PartialBlock (Fmt l1 r1) (Fmt l2 r2) e ee h b ->
    renderPartial scope e ee h b

  -- Special handler that treats it as a regular block with a single ContentStmt
  RawBlock (e :@ el) (b :@ _) ->
    renderSExp scope (PathL (PathID (renderReactExpr scope e) Nothing) :@ el) [] . Just $
      -- FIX Is this right, what happens if this is raw html?
      "function() { return " <> b <> "; },\n"
        <> "function() { return []; }\n"

  -- Decorators are handled in a first pass, so here they are mere formatting
  DecoratorStmt (Fmt l r) a ->
    error "Decorators not implemented "

  DecoratorBlock (Fmt l _) (Fmt _ r) _ _ ->
    error "Decorators not implemented "

  Tag (n :@ _) attr (b :@ _) ->
    let
      attributeMapping k = if k == "class" then "className" else k
      as = T.intercalate ", " . fmap (\(Attribute k v) -> attributeMapping k <> ": " <> "'" <> v <> "'") . fmap depo $ attr
    in
      "React.createElement('" <> n <> "', { " <> as <> "}, " <> renderReactTemplate scope b <> ")"

-- FIX This can't be anything but SExp
renderBlock ::
  Scope ->
  Positioned Expr ->
  Maybe (Positioned BlockParams) ->
  Positioned Template ->
  Positioned Template ->
  Text
renderBlock scope ((SExp l es _) :@ _) bp (b :@ _) (i :@ _) =
  let
    depth = T.pack . show . length $ scope
    args' = maybe ["args" <> depth] (\(BlockParams bp' :@ _) -> fmap (\(l :@ _) -> renderReactLiteral [] l) $ bp') bp
    args = T.intercalate ", " args'
  in
    -- TODO: Worth making these helpers return a function that takes _more_ arguments?
    -- This would mean not passing in everything to renderSExp
    renderSExp scope l es . Just $
         -- NOTE: Pass data first because we can have 0..n _named_ arguments
         "function(data, " <> args <> ") { return " <> renderReactTemplate (args' : scope) b <> " }, "
      <> "function(data, args" <> depth <> ") { return " <> renderReactTemplate scope i <> " }"

renderPartial :: Scope -> Positioned Expr -> Maybe (Positioned Expr) -> Positioned Hash -> Positioned Template -> Text
renderPartial scope (e :@ _) ee (Hash hash :@ _) (b :@ _) =
  "context.partials" <> partialName e <> "("
    -- FIX Yuck
    -- NOTE: We want to ignore the "new" scope here, hence the '_args' name
    <> "{ helpers: context.helpers, partials: Object.assign({}, context.partials, { '__PARTIAL_BLOCK__': function(context, _args, data) { return " <> renderReactTemplate scope b <> "; }})}, "
    <> "Object.assign({}, "
      <> maybe "{}" (\(ee' :@ _) -> renderReactExpr scope ee') ee <> ", "
      <> "{" <> (T.intercalate ", " . fmap (\((HashPair (k :@ _) (v :@ _)) :@ _) -> k <> ": " <> renderReactExpr scope v)) hash <> "}"
    <> "), "
    <> "{ 'partial-block': '__PARTIAL_BLOCK__' }"
    <> ")"
  where
    partialName e' =
      case e' of
        Lit ((DataL _) :@ _) ->
          "[" <> renderReactExpr [] e' <> "]"
        _ ->
          renderJsArg (renderReactExpr [] e')

renderReactExpr :: Scope -> Expr -> Text
renderReactExpr scope e = case e of
  Lit (l :@ _) ->
    renderReactLiteral scope l
  SExp l es h ->
    renderSExp scope l es Nothing

renderSExp :: Scope -> Positioned Literal -> [Positioned Expr] -> Maybe Text -> Text
renderSExp scope (l :@ _) es b =
  "context.helpers" <> renderJsArg (renderReactLiteral [] l) <> "("
    <> scopeHead scope <> ", "
    <> "[" <> (T.intercalate ", " . fmap (\(e :@ _) -> renderReactExpr scope e)) es <> "]"
    <> maybe "" (", " <>) b
    <> ")"

renderReactLiteral :: Scope -> Literal -> Text
renderReactLiteral scope l = case l of
  PathL p ->
    -- TODO Is used by helpers, which is wrong!
    renderReactPath scope p
  DataL (DataPath dp) ->
    -- Data is _only_ passed in from block callbacks
    "data" <> renderJsArg (renderReactPath scope dp)
  StringL t ->
    "'" <> t <> "'"
  NumberL i ->
    T.pack . show $ i
  BooleanL b ->
    case b of
      False ->
        "false"
      True ->
        "true"
  NullL ->
    "null"

-- Pure vanity, render arguments nicely if possible
renderJsArg :: Text -> Text
renderJsArg a =
  case T.all C.isAlpha a of
    True ->
      "." <> a
    False ->
      "['" <> a <> "']"

renderReactPath :: Scope -> Path -> Text
renderReactPath scope p = case p of
  -- TODO "../"
  PathID t m ->
    let
      t' = T.intercalate "." $ case scope of
        [] ->
          [t]
        h : _ ->
          case elem t h of
            True ->
              [t]
            False ->
              -- TODO Yeah this is wrong, what happens if you're eaching on an object and you only declare key?!?!
              -- Kill me if we ever admit that 'this' is a thing
              (maybe [] pure . head . reverse) h <> [t]
    in
      case (t, m) of
        ("..", Just ('/', p')) ->
          renderReactPath (drop 1 scope) p'
        _ ->
          t' <> maybe "" (\(c, p') -> T.singleton c <> renderReactPath [] p') m
  PathSeg t m ->
    t <> maybe "" (\(c, p') -> T.singleton c <> renderReactPath [] p') m

scopeHead :: Scope -> Text
scopeHead scope =
  case scope of
    [] ->
      ""
    h : _ ->
      -- TODO Yeah this is wrong, what happens if you're eaching on an object and you only declare key?!?!
      -- Kill me if we ever admit that 'this' is a thing
      (fromMaybe "" . head . reverse) h