# Layout.jl - WasmTarget.jl documentation layout
#
# Uses Suite.jl SiteNav for shared navbar pattern, SiteFooter, Separator,
# Toaster. Uses WasmTarget.jl accent colors (Purple primary, Red secondary).

import Suite

# --- Logo ---

function WasmTargetLogo()
    A(:href => "./", :class => "flex items-center",
        Span(:class => "text-2xl font-bold", :style => "color: var(--brand-name)", "WasmTarget"),
        Span(:class => "text-2xl font-light",
            Span(:style => "color: var(--jl-dot)", "."),
            Span(:style => "color: var(--jl-j)", "j"),
            Span(:style => "color: var(--jl-l)", "l")
        )
    )
end

# --- Navigation links ---

const _WASMTARGET_NAV_LINKS = [
    (href="./", label="Home", exact=true),
    (href="./playground/", label="Playground"),
    (href="./manual/", label="Manual"),
    (href="./features/", label="Features", exact=true),
    (href="./api/", label="API", exact=true),
]

const _WASMTARGET_MOBILE_SECTIONS = [
    (title="Explore", links=[
        (href="./playground/", label="Playground"),
        (href="./features/", label="Features"),
        (href="./api/", label="API Reference"),
    ]),
    (title="Manual", links=[
        (href="./manual/", label="Overview"),
        (href="./manual/variables/", label="Variables"),
        (href="./manual/integers-floats/", label="Integers & Floats"),
        (href="./manual/math-operations/", label="Math Operations"),
        (href="./manual/strings/", label="Strings"),
        (href="./manual/functions/", label="Functions"),
        (href="./manual/control-flow/", label="Control Flow"),
        (href="./manual/types/", label="Types"),
        (href="./manual/methods/", label="Methods"),
        (href="./manual/arrays/", label="Arrays"),
        (href="./manual/tuples/", label="Tuples"),
    ]),
]

const _WASMTARGET_GITHUB = "https://github.com/GroupTherapyOrg/WasmTarget.jl"

# Custom theme options — Minimal is the default for WasmTarget.jl
const _WASMTARGET_THEMES = [
    (name="Minimal", key="default", description="Zinc — sharp and clean", swatch="#71717a"),
    (name="Classic", key="classic", description="Purple — warm scholarly tones", swatch="#9558b2"),
    (name="Ocean", key="ocean", description="Blue — professional and confident", swatch="#2563eb"),
    (name="Nature", key="nature", description="Emerald — organic and earthy", swatch="#059669"),
]

# --- Main Layout ---

"""
Main documentation layout with Suite.jl SiteNav, footer, and theme support.
"""
function Layout(children...; title="WasmTarget.jl")
    Div(:class => "min-h-screen flex flex-col bg-warm-50 dark:bg-warm-950 transition-colors duration-200",
        # Navigation bar (Suite.SiteNav handles desktop + mobile + theme controls)
        Suite.SiteNav(
            WasmTargetLogo(),
            _WASMTARGET_NAV_LINKS,
            _WASMTARGET_GITHUB;
            mobile_title="WasmTarget.jl",
            mobile_sections=_WASMTARGET_MOBILE_SECTIONS,
            themes=_WASMTARGET_THEMES
        ),

        # Main Content — SPA navigation swaps this area
        MainEl(:id => "page-content", :class => "flex-1 w-full max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8",
            children...
        ),

        # Footer separator
        Suite.Separator(),

        # Footer
        Suite.SiteFooter(
            Suite.FooterBrand(
                Span(:class => "text-sm font-medium text-warm-800 dark:text-warm-300", "GroupTherapyOrg"),
            ),
            Suite.FooterLinks(
                Suite.FooterLink("WasmTarget.jl", href="https://github.com/GroupTherapyOrg/WasmTarget.jl"),
                Suite.FooterLink("Therapy.jl", href="https://github.com/GroupTherapyOrg/Therapy.jl"),
                Suite.FooterLink("Suite.jl", href="https://github.com/GroupTherapyOrg/Suite.jl"),
            ),
            Suite.FooterTagline("Built with Therapy.jl — Julia to WebAssembly compiler"),
        ),

        # Toast notification container
        Suite.Toaster()
    )
end
