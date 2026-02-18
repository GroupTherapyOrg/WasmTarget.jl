# Playground page - Embeds the working Julia-to-WASM playground
#
# The standalone playground (browser/playground.html) is copied to dist/playground/
# during build as app.html. This route wraps it in the docs layout via an iframe.

function PlaygroundPage()
    Div(:class => "w-full -mx-4 sm:-mx-6 lg:-mx-8 -mb-8",
        :style => "min-height: calc(100vh - 120px);",

        Iframe(
            :src => "app.html",
            :style => "width: 100%; height: calc(100vh - 120px); border: none;",
            :title => "WasmTarget.jl Playground",
            :loading => "eager"
        )
    )
end

# Export
PlaygroundPage
