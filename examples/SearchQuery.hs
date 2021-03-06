import Streamly
import Streamly.Prelude (nil, yieldM, (|:))
import Network.HTTP.Simple

-- | Runs three search engine queries in parallel and prints the search engine
-- names in the fastest first order.
--
-- Does it twice using two different ways.
--
main :: IO ()
main = do
    putStrLn "Using parallel stream construction"
    runStream . parallely $ google |: bing |: duckduckgo |: nil

    putStrLn "\nUsing parallel semigroup composition"
    runStream . parallely $ yieldM google <> yieldM bing <> yieldM duckduckgo

    putStrLn "\nUsing parallel applicative zip"
    runStream . zipAsyncly $
        (,,) <$> yieldM google <*> yieldM bing <*> yieldM duckduckgo

    where
        get :: String -> IO ()
        get s = httpNoBody (parseRequest_ s) >> putStrLn (show s)

        google, bing, duckduckgo :: IO ()
        google     = get "https://www.google.com/search?q=haskell"
        bing       = get "https://www.bing.com/search?q=haskell"
        duckduckgo = get "https://www.duckduckgo.com/?q=haskell"
