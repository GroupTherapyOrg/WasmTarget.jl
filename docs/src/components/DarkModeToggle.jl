# ── DarkModeToggle ──
# Module-level signal — shared across ALL DarkModeToggle instances on the page.
# Captures the standard Therapy pattern: create_signal at file scope, capture in @island.

const dark_mode = create_signal(0)

@island function DarkModeToggle()
    # Capture the module-level signal (auto-detected as shared by the compiler)
    is_dark, set_dark = dark_mode

    # Sync signal with actual DOM state on hydration
    # (head script already set 'dark' class from localStorage/OS preference)
    js("if(document.documentElement.classList.contains('dark'))\$1(1)", set_dark)

    return Button(
        :on_click => () -> begin
            set_dark(1 - is_dark())
            js("document.documentElement.classList.toggle('dark')")
            js("var bp = document.documentElement.getAttribute('data-base-path') || ''")
            js("var sk = bp ? 'therapy-theme:' + bp : 'therapy-theme'")
            js("localStorage.setItem(sk, document.documentElement.classList.contains('dark') ? 'dark' : 'light')")
        end,
        :class => "text-warm-500 dark:text-warm-400 hover:text-warm-700 dark:hover:text-warm-300 transition-colors cursor-pointer",
        RawHtml("""<svg class="w-5 h-5 dark:hidden" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"/></svg><svg class="w-5 h-5 hidden dark:block" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>""")
    )
end
