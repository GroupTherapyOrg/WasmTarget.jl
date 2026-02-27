# Playground — TBD
#
# Not yet implemented. Placeholder page to avoid misleading visitors.

import Suite

function PlaygroundPage()
    Div(:class => "w-full max-w-4xl mx-auto py-16",
        Div(:class => "text-center",
            H1(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100 mb-4",
                "Playground"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto mb-8",
                "This page is not yet implemented."
            ),
            Suite.Alert(class="max-w-xl mx-auto",
                Suite.AlertTitle("Coming Soon"),
                Suite.AlertDescription(
                    "The interactive playground is under development. Check back later."
                )
            ),
            Div(:class => "mt-8",
                A(:href => "./features/",
                    Suite.Button("See Features")
                )
            )
        )
    )
end

# Export
PlaygroundPage
