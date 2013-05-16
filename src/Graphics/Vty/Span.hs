{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
-- Copyright 2009-2010 Corey O'Connor
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- The ops to define the content for an output region. 
module Graphics.Vty.Span
    where

import Graphics.Vty.Image
import Graphics.Vty.Image.Internal
import Graphics.Vty.Picture
import Graphics.Vty.DisplayRegion
import Graphics.Text.Width

import Control.Lens
import Control.Monad ( forM_ )
import Control.Monad.Reader.Strict
import Control.Monad.State.Strict
import Control.Monad.ST.Strict hiding ( unsafeIOToST )
import Control.Monad.ST.Unsafe ( unsafeIOToST )

import Data.Monoid
import Data.Vector (Vector)
import qualified Data.Vector as Vector hiding ( take, replicate )
import Data.Vector.Mutable ( MVector(..))
import qualified Data.Vector.Mutable as Vector

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BLInt
import qualified Data.Foldable as Foldable
import qualified Data.Text.Lazy as TL
import Data.Word

import Foreign.Storable ( pokeByteOff )

-- | Currently append in the Monoid instance is equivalent to <->. 
instance Monoid Image where
    mempty = EmptyImage
    mappend = (<->)

{- | A picture is translated into a sequences of state changes and character spans.
 - State changes are currently limited to new attribute values. The attribute is applied to all
 - following spans. Including spans of the next row.  The nth element of the sequence represents the
 - nth row (from top to bottom) of the picture to render.
 -
 - A span op sequence will be defined for all rows and columns (and no more) of the region provided
 - with the picture to spans_for_pic.
 - 
 - todo: Partition attribute changes into multiple categories according to the serialized
 - representation of the various attributes.
 -}

data DisplayOps = DisplayOps
    { effected_region :: DisplayRegion 
    , display_ops :: RowOps
    }

-- | vector of span operation vectors. One per row of the screen.
type RowOps = Vector SpanOps

type MRowOps s = MVector s SpanOps

-- | vector of span operations. executed in succession. This represents the operations required to
-- render a row of the terminal. The operations in one row may effect subsequent rows.
-- EG: Setting the foreground color in one row will effect all subsequent rows until the foreground
-- color is changed.
type SpanOps = Vector SpanOp

type MSpanOps s = MVector s SpanOp

instance Show DisplayOps where
    show (DisplayOps _ the_row_ops)
        = "{ " ++ (show $ Vector.map (\ops -> show ops ++ "; " ) the_row_ops) ++ " }"

instance Show SpanOp where
    show (AttributeChange attr) = show attr
    show (TextSpan ow cw _) = "TextSpan " ++ show ow ++ " " ++ show cw

-- | Number of columns the DisplayOps are defined for
span_ops_columns :: DisplayOps -> Word
span_ops_columns ops = region_width $ effected_region ops

-- | Number of rows the DisplayOps are defined for
span_ops_rows :: DisplayOps -> Word
span_ops_rows ops = region_height $ effected_region ops

-- | The number of columns a SpanOps effects.
span_ops_effected_columns :: SpanOps -> Word
span_ops_effected_columns in_ops = Vector.foldl' span_ops_effected_columns' 0 in_ops
    where 
        span_ops_effected_columns' t (TextSpan w _ _ ) = t + w
        span_ops_effected_columns' t _ = t

-- | This represents an operation on the terminal. Either an attribute change or the output of a
-- text string.
-- 
-- todo: This type may need to be restructured to increase sharing in the bytestring
-- 
-- todo: Make foldable
data SpanOp =
      AttributeChange !Attr
    -- | a span of UTF-8 text occupies a specific number of screen space columns. A single UTF
    -- character does not necessarially represent 1 colunm. See Codec.Binary.UTF8.Width
    -- TextSpan [output width in columns] [number of characters] [data]
    | TextSpan !Int !Int BL.ByteString
    deriving Eq

-- | The width of a single SpanOp in columns
span_op_has_width :: SpanOp -> Maybe (Int, Int)
span_op_has_width (TextSpan ow cw _) = Just (cw, ow)
span_op_has_width _ = Nothing

-- | returns the number of columns to the character at the given position in the span op
columns_to_char_offset :: Int -> SpanOp -> Int
columns_to_char_offset cx (TextSpan _ _ utf8_str) =
    let str = TL.unpack (TL.decodeUtf8 utf8_str)
    in wcswidth (take cx str)
columns_to_char_offset _cx _ = error "columns_to_char_offset applied to span op without width"

-- | Produces the span ops that will render the given picture, possibly cropped or padded, into the
-- specified region.
spans_for_pic :: Picture -> DisplayRegion -> DisplayOps
spans_for_pic pic r = DisplayOps r $ Vector.create (build_spans pic r)

-- transform plus clip. More or less.
newtype BlitState = BlitState
    -- we always snoc to the operation vectors. Thus the column_offset = length of row at row_offset
    {  _row_offset :: Int
    -- clip coordinate space is in image space. Which means it's >= 0 and < image_width.
    , _skip_columns :: Int
    -- >= 0 and < image_height
    , _skip_rows :: Int
    -- includes consideration of skip_columns. In display space.
    -- The number of columns from the next column to be defined to the end of the display for the
    -- row.
    , _remaining_columns :: Int
    -- includes consideration of skip_rows. In display space.
    , _remaining_rows :: Int
    }

makeLenses ''BlitState

newtype BlitEnv s = BlitEnv
    { _bg :: Background
    , _region :: DisplayRegion
    , _mrow_ops :: MRowOps s
    }

makeLenses ''BlitEnv

type BlitM s a = ReaderT (BlitEnv s) (StateT BlitState (ST s)) a

-- | Builds a vector of row operations that will output the given picture to the terminal.
--
-- Crops to the given display region.
build_spans :: Picture -> DisplayRegion -> ST s (MRowOps s)
build_spans pic region = do
    -- First we create a mutable vector for each rows output operations.
    mrow_ops <- Vector.replicate (region_height region) Vector.empty
    -- \todo I think building the span operations in display order would provide better performance.
    -- However, I got stuck trying to implement an algorithm that did this. This will be considered
    -- as a possible future optimization. 
    --
    -- A depth first traversal of the image is performed.  ordered according to the column range
    -- defined by the image from least to greatest.  The output row ops will at least have the
    -- region of the image specified. Iterate over all output rows and output background fills for
    -- all unspecified columns.
    --
    -- The images are made into span operations from left to right. It's possible that this could
    -- easily be made to assure top to bottom output as well. 
    if region_height region > 0
        then do 
            -- The ops builder recursively descends the image and outputs span ops that would
            -- display that image. The number of columns remaining in this row before exceeding the
            -- bounds is also provided. This is used to clip the span ops produced to the display.
            -- The skip dimensions provided do....???
            _ <- runStateT (runReaderT (start_image_build $ pic_image pic)
                                       (BlitEnv (pic_background pic) region mrow_ops)
                           )
                           (BlitState 0 0 0 0 (region_width region) (region_height region))
            -- Fill in any unspecified columns with the background pattern.
            -- todo: If there is no background pattern defined then skip
            forM_ [0 .. (region_height region - 1)] $! \row -> do
                end_x <- Vector.read mrow_ops row >>= return . span_ops_effected_columns
                if end_x < region_width region 
                    then snoc_bg_fill mrow_ops (pic_background pic) (region_width region - end_x) row
                    else return ()
        else return ()
    return mrow_ops

-- | Add the operations required to build a given image to the current set of row operations
-- returns the number of columns and rows contributed to the output.
start_image_build :: Image -> BlitM s ()
start_image_build image = do
    out_of_bounds <- is_out_of_bounds image <$> get
    if out_of_bounds
        then return (0,0)
        else add_maybe_clipped image

is_out_of_bounds :: Image -> BlitState -> Bool
is_out_of_bounds image s
    | s ^. remaining_columns <= 0 = True
    | s ^. remain_rows       <= 0 = True
    | otherwise                   = False

add_maybe_clipped :: Image -> BlitM s ()
add_maybe_clipped EmptyImage = return ()
-- The width provided is the number of columns this text span will occupy when displayed.
-- if this is greater than the number of remaining columsn the output has to be produced a
-- character at a time.
--
-- TODO: prove this cannot be called in fully clipped case
add_maybe_clipped (HorizText text_str _ow _cw) =
    use row_offset >>= snoc_op (AttributeChange a)
    left_clip <- use skip_columns
    right_clip <- use remaining_columns
    let left_clipped = left_clip > 0
        right_clipped = (ow - left_clip) > right_clip
    if left_clipped || right_clipped
        then let text_str' = clip_text left_clip right_clip
             in render_unclipped_text_span text_str'
        else render_unclipped_text_span text_str
process_image (VertJoin top_image bottom_image _ _) = do
            (skip_row',skip_col') <- row_ops_for_image mrow_ops 
                                                       top_image
                                                       bg 
                                                       region 
                                                       skip_dim 
                                                       y 
                                                       remaining_columns
                                                       remain_rows
            let top_height = (image_height top_image) - (skip_row - skip_row')
            (skip_row'',skip_col'') <- row_ops_for_image mrow_ops 
                                                         bottom_image
                                                         bg 
                                                         region 
                                                         (skip_row', skip_col) 
                                                         (y + top_height)
                                                         remaining_columns
                                                         (max 0 $ remain_rows - top_height)
            return (skip_row'', min skip_col' skip_col'')
        HorizJoin l r _ _ -> do
            (skip_row',skip_col') <- row_ops_for_image mrow_ops l bg region skip_dim y remaining_columns remain_rows
            -- Don't output the right part unless there is at least a single column left after
            -- outputting the left part.
            if image_width l - (skip_col - skip_col') > remaining_columns
                then return (skip_row,skip_col')
                else do
                    (skip_row'',skip_col'') <- row_ops_for_image mrow_ops r bg region (skip_row, skip_col') y (remaining_columns - image_width l + (skip_col - skip_col')) remain_rows
                    return (min skip_row' skip_row'', skip_col'')
        BGFill width height -> do
            let min_height = if y + height > (region_height region)
                                then region_height region - y
                                else min height remain_rows
                min_width = min width remaining_columns
                actual_height = if skip_row > min_height
                                    then 0
                                    else min_height - skip_row
                actual_width = if skip_col > min_width
                                    then 0
                                    else min_width - skip_col
            forM_ [y .. y + actual_height - 1] $! \y' -> snoc_bg_fill mrow_ops bg actual_width y'
            let skip_row' = if actual_height > skip_row
                                then 0
                                else skip_row - min_height
                skip_col' = if actual_width > skip_col
                                then 0
                                else skip_col - min_width
            return (skip_row',skip_col')
        ImageCrop (max_w,max_h) i ->
            row_ops_for_image mrow_ops i bg region skip_dim y (min remaining_columns max_w) (min remain_rows max_h)

render_clipped_text_span :: DisplayString -> Int -> Int -> BlitM ()
render_clipped_text_span txt left_skip right_clip = do
    use row_offset >>= snoc_op (AttributeChange a)
    -- TODO: store a skip list in HorizText
    let (to_drop,pad_prefix) = clip_for_char_width left_skip txt 0
        txt' = TL.append (if pad_prefix then TL.singleton '…' else TL.empty) (TL.drop to_drop txt)
        (to_take,pad_suffix) = clip_for_char_width right_clip txt' 0
        txt'' = TL.append (TL.take to_take txt') (if pad_suffix then TL.singleton '…' else TL.empty)
        clip_for_char_width 0 _ n = (n, False)
        clip_for_char_width 1 t n
            | wcwidth (TL.head t) == 1 = (n+1, False)
            | otherwise                = (n, True)
        clip_for_char_width lc t n
            = apply_left_clip (lc - wcwidth (TL.head t)) (TL.rest t) (n + 1)
    render_unclipped_text_span a txt''

render_unclipped_text_span :: DisplayString -> BlitM ()
render_unclipped_text_span txt = do
    let op = TextSpan used_display_columns (TL.length txt) (TL.encodeUtf8 txt)
        used_display_columns = wcswidth $ TL.unpack txt
    use row_offset >>= snoc_op op

-- | Add a background fill of the given column width to the row display operations.
--
-- This has a fast path for background characters that are a single column and a single byte.
-- Otherwise this has to compute the width of the background character and replicate a sequence of
-- bytes to fill in the required width.
snoc_bg_fill :: MRowOps s -> Background -> Int -> Int -> ST s ()
snoc_bg_fill _row_ops _bg 0 _row 
    = return ()
snoc_bg_fill mrow_ops (Background c back_attr) fill_length row 
    = do
        snoc_op mrow_ops row $ AttributeChange back_attr
        -- By all likelyhood the background character will be an ASCII character. Which is a single
        -- byte in utf8. Optimize for this special case.
        utf8_bs <- if c <= (toEnum 255 :: Char)
            then
                let !(c_byte :: Word8) = BInt.c2w c
                in unsafeIOToST $ do
                    BInt.create fill_length
                                $ \ptr -> mapM_ (\i -> pokeByteOff ptr i c_byte)
                                                [0 .. (fill_length - 1)]
            else 
                let !(c_bytes :: [Word8]) = encode [c]
                in unsafeIOToST $ do
                    BInt.create (fill_length * length c_bytes) 
                                $ \ptr -> mapM_ (\(i,b) -> pokeByteOff ptr i b)
                                                $ zip [0 .. (fill_length - 1)] (cycle c_bytes)
        snoc_op mrow_ops row $ TextSpan fill_length fill_length (UTF8.fromRep utf8_bs)

-- | snocs the operation to the operations for the given row.
snoc_op :: SpanOp -> Int -> BlitM s ()
snoc_op !op !row = do
    the_mrow_ops <- view mrow_ops
    lift $ do
        ops <- Vector.read the_mrow_ops row
        let ops' = Vector.snoc ops op
        Vector.write the_mrow_ops row ops'

