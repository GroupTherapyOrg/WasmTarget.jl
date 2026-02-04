# Editor.jl - Playground code editor component
#
# A server component that provides a code editor with:
# - Syntax highlighting via Prism.js
# - Editable textarea for user code input
# - Tab key handling for indentation
# - Copy to clipboard functionality
# - Integration with example selector via localStorage
#
# Note: This is a server component (not an island) because:
# - String signals don't compile to WASM properly
# - Code editing requires full DOM access via JS
# - The pattern follows the existing JuliaPlayground component
#
# Story: PLAYGROUND-020

"""
Playground code editor component.

Displays Julia code with syntax highlighting and allows editing.
Uses client-side JS for textarea interaction and Prism.js for highlighting.

Arguments:
- `initial_code::String` - Default code to display in the editor
- `id::String` - Unique ID for targeting by JS (default: "playground-editor")
- `editable::Bool` - Whether user can edit the code (default: true)

Usage:
    PlaygroundEditor(
        initial_code = "function add(a, b) a + b end",
        editable = true
    )
"""
function PlaygroundEditor(;
    initial_code::String = "",
    id::String = "playground-editor",
    editable::Bool = true
)
    editor_id = "$(id)-textarea"
    display_id = "$(id)-display"

    Div(:class => "flex flex-col h-full",
        # Header bar
        Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
            # Language indicator
            Span(:class => "text-stone-300 text-sm font-medium", "Julia"),
            # Action buttons
            Div(:class => "flex items-center gap-3",
                # Copy button
                Button(:id => "$(id)-copy-btn",
                       :class => "text-stone-400 hover:text-white text-xs flex items-center gap-1 transition-colors",
                       :title => "Copy code to clipboard",
                    Svg(:class => "w-3.5 h-3.5", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3")
                    ),
                    Span("Copy")
                ),
                # Clear button (if editable)
                editable ?
                    Button(:id => "$(id)-clear-btn",
                           :class => "text-stone-400 hover:text-white text-xs flex items-center gap-1 transition-colors",
                           :title => "Clear editor",
                        Svg(:class => "w-3.5 h-3.5", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                 :d => "M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16")
                        ),
                        Span("Clear")
                    ) : nothing
            )
        ),

        # Editor area - dual layer: textarea for input, pre/code for highlighting
        Div(:class => "relative flex-1 min-h-[300px]",
            # Textarea for actual input (editable layer)
            editable ?
                Textarea(:id => editor_id,
                         :class => "absolute inset-0 w-full h-full bg-transparent text-transparent caret-white p-4 font-mono text-sm resize-none focus:outline-none focus:ring-2 focus:ring-cyan-500/50 z-10",
                         :spellcheck => "false",
                         :autocomplete => "off",
                         :autocorrect => "off",
                         :autocapitalize => "off",
                         :placeholder => "Write Julia code here...",
                         :aria_label => "Julia code editor",
                         initial_code
                ) : nothing,

            # Highlighted display layer
            Pre(:id => display_id,
                :class => "absolute inset-0 w-full h-full bg-stone-800 dark:bg-stone-900 p-4 overflow-auto text-sm pointer-events-none rounded-b-xl",
                :aria_hidden => "true",
                Code(:class => "language-julia text-stone-100 font-mono whitespace-pre-wrap",
                     initial_code)
            )
        ),

        # Client-side JS for editor behavior
        Script("""
            (function() {
                const textarea = document.getElementById('$(editor_id)');
                const display = document.getElementById('$(display_id)');
                const displayCode = display ? display.querySelector('code') : null;
                const copyBtn = document.getElementById('$(id)-copy-btn');
                const clearBtn = document.getElementById('$(id)-clear-btn');

                // Sync textarea content to highlighted display
                function syncDisplay() {
                    if (textarea && displayCode) {
                        // Add a trailing newline to prevent scrollbar jumping
                        displayCode.textContent = textarea.value + '\\n';
                        // Re-highlight with Prism if available
                        if (typeof Prism !== 'undefined') {
                            Prism.highlightElement(displayCode);
                        }
                    }
                }

                // Tab key handling for indentation
                if (textarea) {
                    textarea.addEventListener('keydown', function(e) {
                        if (e.key === 'Tab') {
                            e.preventDefault();
                            const start = this.selectionStart;
                            const end = this.selectionEnd;

                            if (e.shiftKey) {
                                // Shift+Tab: dedent
                                const lineStart = this.value.lastIndexOf('\\n', start - 1) + 1;
                                const lineContent = this.value.substring(lineStart, start);
                                if (lineContent.startsWith('    ')) {
                                    this.value = this.value.substring(0, lineStart) +
                                                 this.value.substring(lineStart + 4);
                                    this.selectionStart = this.selectionEnd = start - 4;
                                }
                            } else {
                                // Tab: indent
                                this.value = this.value.substring(0, start) + '    ' + this.value.substring(end);
                                this.selectionStart = this.selectionEnd = start + 4;
                            }
                            syncDisplay();
                        }
                    });

                    // Sync on input
                    textarea.addEventListener('input', syncDisplay);

                    // Sync scroll positions
                    textarea.addEventListener('scroll', function() {
                        if (display) {
                            display.scrollTop = this.scrollTop;
                            display.scrollLeft = this.scrollLeft;
                        }
                    });

                    // Check for code passed from "Try in Playground" links
                    const savedCode = localStorage.getItem('playground-code');
                    if (savedCode) {
                        textarea.value = savedCode;
                        localStorage.removeItem('playground-code');
                        syncDisplay();
                    }

                    // Dispatch event when code changes (for other components to listen)
                    textarea.addEventListener('input', function() {
                        window.dispatchEvent(new CustomEvent('playground-code-changed', {
                            detail: { code: this.value }
                        }));
                    });
                }

                // Copy button
                if (copyBtn) {
                    copyBtn.addEventListener('click', function() {
                        const code = textarea ? textarea.value : displayCode.textContent;
                        navigator.clipboard.writeText(code).then(() => {
                            const originalText = this.querySelector('span').textContent;
                            this.querySelector('span').textContent = 'Copied!';
                            setTimeout(() => {
                                this.querySelector('span').textContent = originalText;
                            }, 2000);
                        });
                    });
                }

                // Clear button
                if (clearBtn && textarea) {
                    clearBtn.addEventListener('click', function() {
                        textarea.value = '';
                        syncDisplay();
                        textarea.focus();
                        window.dispatchEvent(new CustomEvent('playground-code-changed', {
                            detail: { code: '' }
                        }));
                    });
                }

                // Initial highlight
                if (typeof Prism !== 'undefined') {
                    Prism.highlightElement(displayCode);
                } else {
                    document.addEventListener('DOMContentLoaded', function() {
                        if (typeof Prism !== 'undefined') {
                            Prism.highlightElement(displayCode);
                        }
                    });
                }
            })();
        """)
    )
end

"""
Read-only code display component (no editing).
Use this for showing example code that can't be modified.

Arguments:
- `code::String` - The code to display
- `show_line_numbers::Bool` - Whether to show line numbers (default: false)
"""
function CodeDisplay(;
    code::String,
    show_line_numbers::Bool = false
)
    Div(:class => "rounded-xl overflow-hidden border border-stone-700",
        # Header
        Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800",
            Span(:class => "text-stone-300 text-xs font-medium uppercase tracking-wider", "Julia"),
            # Copy button
            Button(:class => "text-stone-400 hover:text-white text-xs flex items-center gap-1 transition-colors",
                   :data_code => code,
                   :onclick => "navigator.clipboard.writeText(this.dataset.code).then(() => { this.querySelector('span').textContent = 'Copied!'; setTimeout(() => this.querySelector('span').textContent = 'Copy', 2000); })",
                Svg(:class => "w-3.5 h-3.5", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3")
                ),
                Span("Copy")
            )
        ),
        # Code with Prism highlighting
        Pre(:class => "bg-stone-800 dark:bg-stone-900 p-4 overflow-x-auto text-sm",
            Code(:class => "language-julia text-stone-100 font-mono", code)
        ),
        # Prism initialization
        Script("""
            (function() {
                if (typeof Prism !== 'undefined') {
                    Prism.highlightAll();
                }
            })();
        """)
    )
end
