{-# LANGUAGE ViewPatterns #-}

module Data.LLVM.BitCode.IR.Module where

import Data.LLVM.BitCode.Bitstream
import Data.LLVM.BitCode.IR.Attrs
import Data.LLVM.BitCode.IR.Blocks
import Data.LLVM.BitCode.IR.Constants
import Data.LLVM.BitCode.IR.Function
import Data.LLVM.BitCode.IR.Globals
import Data.LLVM.BitCode.IR.Metadata
import Data.LLVM.BitCode.IR.Types
import Data.LLVM.BitCode.IR.Values
import Data.LLVM.BitCode.Match
import Data.LLVM.BitCode.Parse
import Data.LLVM.BitCode.Record
import Text.LLVM.AST

import Control.Monad (foldM,guard)
import Data.List (sortBy)
import Data.Monoid (mempty)
import Data.Ord (comparing)
import qualified Data.Foldable as F
import qualified Data.Sequence as Seq
import qualified Data.Traversable as T


-- Module Block Parsing --------------------------------------------------------

data PartialModule = PartialModule
  { partialGlobalIx   :: !Int
  , partialGlobals    :: GlobalList
  , partialDefines    :: DefineList
  , partialDeclares   :: DeclareList
  , partialDataLayout :: DataLayout
  , partialInlineAsm  :: InlineAsm
  , partialAliasIx    :: !Int
  , partialAliases    :: AliasList
  , partialNamedMd    :: [NamedMd]
  , partialUnnamedMd  :: [PartialUnnamedMd]
  }

emptyPartialModule :: PartialModule
emptyPartialModule  = PartialModule
  { partialGlobalIx   = 0
  , partialGlobals    = mempty
  , partialDefines    = mempty
  , partialDeclares   = mempty
  , partialDataLayout = mempty
  , partialInlineAsm  = mempty
  , partialAliasIx    = 0
  , partialAliases    = mempty
  , partialNamedMd    = mempty
  , partialUnnamedMd  = mempty
  }

-- | Fixup the global variables and declarations, and return the completed
-- module.
finalizeModule :: PartialModule -> Parse Module
finalizeModule pm = do
  globals  <- T.mapM finalizeGlobal       (partialGlobals pm)
  declares <- T.mapM finalizeDeclare      (partialDeclares pm)
  aliases  <- T.mapM finalizePartialAlias (partialAliases pm)
  unnamed  <- T.mapM finalizePartialUnnamedMd (partialUnnamedMd pm)
  types    <- resolveTypeDecls
  let lkp = lookupBlockName (partialDefines pm)
  defines  <- T.mapM (finalizePartialDefine lkp) (partialDefines pm)
  return emptyModule
    { modDataLayout = partialDataLayout pm
    , modNamedMd    = partialNamedMd pm
    , modUnnamedMd  = sortBy (comparing umIndex) unnamed
    , modGlobals    = F.toList globals
    , modDefines    = F.toList defines
    , modTypes      = types
    , modDeclares   = F.toList declares
    , modInlineAsm  = partialInlineAsm pm
    , modAliases    = F.toList aliases
    }

-- | Parse an LLVM Module out of the top-level block in a Bitstream.
parseModuleBlock :: [Entry] -> Parse Module
parseModuleBlock ents = label "MODULE_BLOCK" $ do

  -- the explicit type symbol table has been removed in 3.1, so we parse the
  -- type table, and generate the type symbol table from it.
  tsymtab <- label "type symbol table" $ do
    mb <- match (findMatch typeBlockIdNew) ents
    case mb of
      Just es -> parseTypeBlock es
      Nothing -> return mempty

  withTypeSymtab tsymtab $ do
    -- parse the value symbol table out first, if there is one
    symtab <- do
      mb <- match (findMatch valueSymtabBlockId) ents
      case mb of
        Just es -> parseValueSymbolTableBlock es
        Nothing -> return emptyValueSymtab

    pm <- withValueSymtab symtab
        $ foldM parseModuleBlockEntry emptyPartialModule ents

    finalizeModule pm


-- | Parse the entries in a module block.
parseModuleBlockEntry :: PartialModule -> Entry -> Parse PartialModule

parseModuleBlockEntry pm (blockInfoBlockId -> Just _) =
  -- skip the block info block, as we only use it during Bitstream parsing.
  return pm

parseModuleBlockEntry pm (typeBlockIdNew -> Just _) = do
  -- TYPE_BLOCK_ID_NEW
  -- this is skipped, as it's parsed before anything else, in parseModuleBlock
  return pm

parseModuleBlockEntry pm (constantsBlockId -> Just es) = do
  -- CONSTANTS_BLOCK_ID
  parseConstantsBlock es
  return pm

parseModuleBlockEntry pm (moduleCodeFunction -> Just r) = do
  -- MODULE_CODE_FUNCTION
  parseFunProto r pm

parseModuleBlockEntry pm (functionBlockId -> Just es) = do
  -- FUNCTION_BLOCK_ID
  def <- parseFunctionBlock es
  return pm { partialDefines = partialDefines pm Seq.|> def }

parseModuleBlockEntry pm (paramattrBlockId -> Just _) = do
  -- PARAMATTR_BLOCK_ID
  -- skip for now
  return pm

parseModuleBlockEntry pm (paramattrGroupBlockId -> Just _) = do
  -- PARAMATTR_GROUP_BLOCK_ID
  -- skip for now
  return pm

parseModuleBlockEntry pm (metadataBlockId -> Just es) = do
  -- METADATA_BLOCK_ID
  vt <- getValueTable
  (ns,(gs,_)) <- parseMetadataBlock vt es
  return pm
    { partialNamedMd   = partialNamedMd   pm ++ ns
    , partialUnnamedMd = partialUnnamedMd pm ++ gs
    }

parseModuleBlockEntry pm (valueSymtabBlockId -> Just _) = do
  -- VALUE_SYMTAB_BLOCK_ID
  return pm

parseModuleBlockEntry pm (moduleCodeTriple -> Just _) = do
  -- MODULE_CODE_TRIPLE
  return pm

parseModuleBlockEntry pm (moduleCodeDatalayout -> Just r) = do
  -- MODULE_CODE_DATALAYOUT
  layout <- parseFields r 0 char
  case parseDataLayout layout of
    Nothing -> fail ("unable to parse data layout: ``" ++ layout ++ "''")
    Just dl -> return (pm { partialDataLayout = dl })

parseModuleBlockEntry pm (moduleCodeAsm -> Just r) = do
  -- MODULE_CODE_ASM
  asm <- parseFields r 0 char
  return pm { partialInlineAsm = lines asm }

parseModuleBlockEntry pm (abbrevDef -> Just _) = do
  -- skip abbreviation definitions
  return pm

parseModuleBlockEntry pm (moduleCodeGlobalvar -> Just r) = do
  -- MODULE_CODE_GLOBALVAR
  pg <- parseGlobalVar (partialGlobalIx pm) r
  return pm
    { partialGlobalIx = succ (partialGlobalIx pm)
    , partialGlobals  = partialGlobals pm Seq.|> pg
    }

parseModuleBlockEntry pm (moduleCodeAlias -> Just r) = do
  -- MODULE_CODE_ALIAS
  pa <- parseAlias (partialAliasIx pm) r
  return pm
    { partialAliasIx = succ (partialAliasIx pm)
    , partialAliases = partialAliases pm Seq.|> pa
    }

parseModuleBlockEntry pm (moduleCodeVersion -> Just r) = do
  -- MODULE_CODE_VERSION

  -- please see:
  -- http://llvm.org/docs/BitCodeFormat.html#module-code-version-record
  version <- parseField r 0 numeric
  case version :: Int of
    0 -> setRelIds False  -- Absolute value ids in LLVM <= 3.2
    1 -> setRelIds True   -- Relative value ids in LLVM >= 3.3
    _ -> fail ("unsupported version id: " ++ show version)

  return pm

parseModuleBlockEntry _ e =
  fail ("unexpected: " ++ show e)


parseFunProto :: Record -> PartialModule -> Parse PartialModule
parseFunProto r pm = label "FUNCTION" $ do
  let field = parseField r
  ty      <- getType =<< field 0 numeric
  isProto <-             field 2 numeric

  link    <-             field 3 linkage

  -- push the function type
  ix   <- nextValueId
  name <- entryName ix
  _    <- pushValue (Typed ty (ValSymbol (Symbol name)))

  let proto = FunProto
        { protoType  = ty
        , protoAttrs = emptyFunAttrs
          { funLinkage = do
            -- we emit a Nothing here to maintain output compatibility with
            -- llvm-dis when linkage is External
            guard (link /= External)
            return link
          }
        , protoName  = name
        , protoIndex = ix
        }

  if isProto == (0 :: Int)
     then pushFunProto proto >> return pm
     else return pm { partialDeclares = partialDeclares pm Seq.|> proto }
