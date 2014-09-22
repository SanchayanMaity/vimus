{-# LANGUAGE OverloadedStrings #-}
module Vimus.CommandSpec (main, spec) where

import           Test.Hspec
import           Test.QuickCheck
import           Test.Hspec.Expectations.Contrib

import           Vimus.Type (Vimus)
import           Vimus.Command.Core
import           Vimus.Command.Parser
import           Vimus.Command.Completion
import           Vimus.Command

main :: IO ()
main = hspec spec

type ParseResult a = Either ParseError (a, String)

spec :: Spec
spec = do
  describe "MacroName as an argument" $ do
    describe "argumentParser" $ do
      it "parses key references" $ do
        runParser argumentParser "<ESC>" `shouldBe` Right (MacroName "\ESC", "")

      it "fails on unterminated key references" $ do
        runParser argumentParser "<ESC" `shouldBe` (Left . SpecificArgumentError $ "unterminated key reference \"ESC\"" :: ParseResult MacroName)

      it "fails on invalid key references" $ do
        runParser argumentParser "<foo>" `shouldBe` (Left . SpecificArgumentError $ "unknown key reference \"foo\"" :: ParseResult MacroName)

    describe "completeCommand" $ do
      let complete = completeCommand [command "map" "" (undefined :: MacroName -> MacroExpansion -> Vimus ())]

      it "completes key references" $ do
        complete "map <Es" `shouldBe` Right "map <Esc>"

      it "keeps any prefix on completion" $ do
        complete "map foo<Es" `shouldBe` Right "map foo<Esc>"

  describe "argument MacroExpansion" $ do
    it "is never null" $ property $
      \xs -> case runParser argumentParser xs of
        Left _ -> True
        Right (MacroExpansion ys, _) -> (not . null) ys

  describe "argument ShellCommand" $ do
    it "is never null" $ property $
      \xs -> case runParser argumentParser xs of
        Left _ -> True
        Right (ShellCommand ys, _) -> (not . null) ys

  describe "argument Volume" $ do
    it "returns exact volume value for positve integers" $ do
      runParser argumentParser "10" `shouldBe` Right (Volume 10, "")

    it "returns a positive offset if prefixed by +" $ do
      runParser argumentParser "+10" `shouldBe` Right (VolumeOffset 10, "")

    it "returns a negative offset if prefixed by -" $ do
      runParser argumentParser "-10" `shouldBe` Right (VolumeOffset (-10), "")

    it "returns nothing if given only a sign" $ do
      runParser (argumentParser :: Parser Volume) "+" `shouldSatisfy` isLeft

    it "fails if exact volume exceeds 0-100" $ do
      runParser (argumentParser :: Parser Volume) "110" `shouldSatisfy` isLeft

    it "fails if offset exceeds 0-100" $ do
      runParser (argumentParser :: Parser Volume) "+110" `shouldSatisfy` isLeft
