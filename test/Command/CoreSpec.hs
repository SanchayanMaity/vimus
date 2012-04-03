{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Command.CoreSpec (main, spec) where

import           Test.Hspec.ShouldBe

import           UI.Curses (Color(..), magenta)
import           Command.Core
import           Command.Parser (runParser)

deriving instance Eq Color
deriving instance Show Color

main :: IO ()
main = hspecX spec

spec :: Specs
spec = do

  describe "argumentErrorMessage" $ do
    it "works for one unexpected argument" $ do
      argumentErrorMessage 2 ["foo", "bar", "baz"] `shouldBe` "unexpected argument: baz"

    it "works for multiple unexpected arguments" $ do
      argumentErrorMessage 2 ["foo", "bar", "baz", "qux"] `shouldBe` "unexpected arguments: baz qux"

    it "works for missing arguments" $ do
      argumentErrorMessage 2 ["foo"] `shouldBe` "two arguments required"

  describe "readParser" $ do
    it "parses an integer" $ do
      runParser readParser "10" `shouldBe` Right (10 :: Int, "")

  describe "toAction" $ do
    it "works for arity 0" $ do
      toAction "foo" `runAction` "" `shouldBe` Right "foo"

    it "works for arity 1" $ do
      let f = id :: String -> String
      toAction f `runAction` "foo" `shouldBe` Right "foo"

    it "works for arity 2" $ do
      let f = (+) :: Int -> Int -> Int
      toAction f `runAction` "23 42" `shouldBe` Right (65 :: Int)

    it "works for arity 3" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5 foo magenta" `shouldBe` Right (1.5 :: Double, "foo", magenta)

    it "ignores whitespace at the end of input" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5 foo magenta   " `shouldBe` Right (1.5 :: Double, "foo", magenta)

    it "ignores whitespace at start of input" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "   1.5 foo magenta" `shouldBe` Right (1.5 :: Double, "foo", magenta)

    it "ignores whitespace in-between arguments" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5   foo   magenta" `shouldBe` Right (1.5 :: Double, "foo", magenta)

    it "fails on missing argument" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5 foo" `shouldBe` (Left "missing required argument: color" :: Either String (Double, String, Color))

    it "fails on invalid argument" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5 foo foobar" `shouldBe` (Left "Argument 'foobar' is not a valid color!" :: Either String (Double, String, Color))

    it "fails on unexpected argument" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      toAction f `runAction` "1.5 foo magenta foobar" `shouldBe` (Left "superfluous argument: \"foobar\"" :: Either String (Double, String, Color))

  describe "actionArguments" $ do
    it "given an action, it returns a list of required arguments" $ do
      let f x y z = (x, y, z) :: (Double, String, Color)
      actionArguments f (undefined :: (Double, String, Color)) `shouldBe` ["double", "string", "color"]