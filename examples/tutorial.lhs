> {-# LANGUAGE OverloadedStrings #-}
> import Control.Applicative ((<$>), (<*>))
> import Data.Maybe (isJust)

> import Data.Text (Text)
> import Text.Blaze (Html)
> import qualified Data.Text as T
> import qualified Happstack.Server as Happstack
> import qualified Text.Blaze.Html5 as H

> import Text.Digestive
> import Text.Digestive.Blaze.Html5
> import Text.Digestive.Happstack
> import Text.Digestive.Util

Simple forms and validation
---------------------------

Let's start by creating a very simple datatype to represent a user:

> data User = User
>     { userName :: Text
>     , userMail :: Text
>     } deriving (Show)

And dive in immediately to create a `Form` for a user. The `Form m v a` type
has three parameters:

- `v`: the type for messages and errors (usually a `String`-like type, `Text` in
  this case);
- `m`: the monad we are operating in, not specified here;
- `a`: the return type of the `Form`, in this case, this is obviously `User`.

> userForm :: Monad m => Form Text m User

We create forms by using the `Applicative` interface. A few form types are
provided in the `Text.Digestive.Form` module, such as `text`, `string`,
`bool`...

In the `digestive-functors` library, the developper is required to label each
field using the `.:` operator. This might look like a bit of a burden, but it
allows youto do some really useful stuff, like separating the `Form` from the
actual HTML layout.

> userForm = User
>     <$> "name" .: text Nothing
>     <*> "mail" .: check "Not a valid email address" checkEmail (text Nothing)

The `check` function enables you to validate the result of a form. For example,
we can validate the email address with a really naive `checkEmail` function.

> checkEmail :: Text -> Bool
> checkEmail = isJust . T.find (== '@')

More validation
---------------

For our example, we also want descriptions of Haskell libraries, and in order to
do that, we need package versions...

> type Version = [Int]

We want to let the user input a version number such as `0.1.0.0`. This means we
need to validate if the input `Text` is of this form, and then we need to parse
it to a `Version` type. Fortunately, we can do this in a single function:
`validate` allows conversion between values, which can optionally fail.

`readMaybe :: Read a => String -> Maybe a` is a utility function imported from
`Text.Digestive.Util`.

> validateVersion :: Text -> Result Text Version
> validateVersion = maybe (Error "Cannot parse version") Success .
>     mapM (readMaybe . T.unpack) . T.split (== '.')

A quick test in GHCi:

    ghci> validateVersion (T.pack "0.3.2.1")
    Success [0,3,2,1]
    ghci> validateVersion (T.pack "0.oops")
    Error "Cannot parse version"

It works! This means we can now easily add a `Package` type and a `Form` for it:

> data Package = Package Text Version
>     deriving (Show)

> packageForm :: Monad m => Form Text m Package
> packageForm = Package
>     <$> "name"    .: text Nothing
>     <*> "version" .: validate validateVersion (text (Just "0.0.0.0"))

Composing forms
---------------

A release has an author and a package. Let's use this to illustrate the
composability of the digestive-functors library: we can reuse the forms we have
written earlier on.

> data Release = Release User Package
>     deriving (Show)

> releaseForm :: Monad m => Form Text m Release
> releaseForm = Release
>     <$> "author"  .: userForm
>     <*> "package" .: packageForm

Views
-----

As mentioned before, one of the advantages of using digestive-functors is
separation of forms and their actual HTML layout. In order to do this, we have
another type, `View`.

We can get a `View` from a `Form` by supplying input. A `View` contains more
information than a `Form`, it has:

- the original form;
- the input given by the user;
- any errors that have occurred.

It is this view that we convert to HTML. For this tutorial, we use the
[blaze-html] library, and some helpers from the `digestive-functors-blaze`
library.

[blaze-html]: http://jaspervdj.be/blaze/

Let's write a view for the `User` form. As you can see, we here refer to the
different fields in the `userForm`. The `errorList` will generate a list of
errors for the `"mail"` field.

> userView :: View Html -> Html
> userView view = do
>     label     "name" view "Name: "
>     inputText "name" view
>     H.br
>
>     errorList "mail" view
>     label     "mail" view "Email address: "
>     inputText "mail" view
>     H.br

Like forms, views are also composable: let's illustrate that by adding a view
for the `releaseForm`, in which we reuse `userView`. In order to do this, we
take only the parts relevant to the author from the view by using `subView`. We
can then pass the resulting view to our own `userView`.

We have no special view code for `Package`, so we can just add that to
`releaseView` as well. `childErrorList` will generate a list of errors for each
child of the specified form. In this case, this means a list of errors from
`"package.name"` and `"package.version"`. Note how we use `foo.bar` to refer to
nested forms.

> releaseView :: View Html -> Html
> releaseView view = do
>     H.h2 "Author"
>     userView $ subView "author" view
>
>     H.h2 "Package"
>     childErrorList "package" view
>     label     "package.name" view "Name: "
>     inputText "package.name" view
>     label     "package.version" view "Version: "
>     inputText "package.version" view

The attentive reader might have wondered what the type parameter for `View` is:
it is the `String`-like type used for e.g. error messages.

But wait! We have

    releaseForm :: Monad m => Form Text m Release
    releaseView :: View Html -> Html

... doesn't this mean that we need a `View Text` rather than a `View Html`?  The
answer is yes -- but having `View Html` allows us to write these views more
easily with the `digestive-functors-blaze` library. Fortunately, we will be able
to fix this using the `Functor` instance of `View`.

    fmap :: Monad m => (v -> w) -> View v -> View w

A backend
---------

To finish this tutorial, we need to be able to actually run this code. We need
an HTTP server for that, and we use [Happstack] for this tutorial. The
`digestive-functors-happstack` library gives about everything we need for this.

[Happstack]: http://happstack.com/

> site :: Happstack.ServerPart Happstack.Response
> site = do
>     Happstack.decodeBody $ Happstack.defaultBodyPolicy "/tmp" 4096 4096 4096
>     r <- runForm releaseForm
>     case r of
>         (view, Nothing) -> do
>             let view' = fmap H.toHtml view
>             Happstack.ok $ Happstack.toResponse $ form view' "/" $ do
>                 releaseView view'
>                 H.br
>                 inputSubmit "Submit"
>         (_, Just release) -> Happstack.ok $ Happstack.toResponse $ do
>                 H.h1 "Release received"
>                 H.p $ H.toHtml $ show release
>
> main :: IO ()
> main = Happstack.simpleHTTP Happstack.nullConf site
