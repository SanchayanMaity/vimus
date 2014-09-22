module Vimus.QueueSpec (main, spec) where

import           Test.Hspec

import           Vimus.Queue

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "takeAllQueue" $ do
    it "returns all elements in order" $ do
      q <- newQueue 
      putQueue q 10 >> putQueue q 20 >> putQueue q (30 :: Int)
      takeAllQueue q `shouldReturn` [10, 20, 30]

    it "leaves the queue empty" $ do
      q <- newQueue 
      putQueue q 10 >> putQueue q 20 >> putQueue q (30 :: Int)
      _ <- takeAllQueue q
      takeAllQueue q `shouldReturn` []
