# Playground page — overwritten by post-build step in app.jl
#
# The standalone playground (browser/playground.html) replaces this route's
# generated index.html during build. This file exists only so the route is
# discovered and a dist/playground/ directory is created.

function PlaygroundPage()
    Div(:class => "w-full max-w-4xl mx-auto py-8 text-center",
        P("Loading playground...")
    )
end

# Export
PlaygroundPage
