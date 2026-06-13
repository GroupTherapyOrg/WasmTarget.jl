# Example Database

This directory contains the example database for Supposition.jl. Each file
represents a previously seen counterexample for one invocation of `@check`.
The directory is managed entirely by Supposition.jl - any outside modifications
may be deleted, reverted, changed, modified or undone at a moments notice.

Feel free to add this directory to your `.gitignore` if you don't need past failures
tracked or have too many or too big examples stored here.

If you want to track these somehow/keep them persistent through CI, you can also
pass a custom `DirectoryDB` with a different directory to `@check`.
