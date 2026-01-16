# Home page - Julia REPL Playground
#
# True REPL experience with editable textarea
# Uses client-side JS for UI, WASM for compilation (when runtime ready)

const DEFAULT_CODE = """# Write any Julia code here!
function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Try: sum_to_n(100)
"""

"""
Julia Playground - Full REPL experience.
Regular component (not island) with client-side JS for textarea.
"""
function JuliaPlayground()
    Div(:class => "max-w-6xl mx-auto",
        # Top bar
        Div(:class => "flex items-center justify-between mb-4 flex-wrap gap-2",
            Span(:class => "text-stone-600 dark:text-stone-400 text-sm font-medium",
                "Julia Playground"
            ),
            Button(:id => "run-btn",
                   :class => "flex items-center gap-2 bg-cyan-500 hover:bg-cyan-600 text-white px-6 py-2 rounded-lg font-semibold transition-colors shadow-lg shadow-cyan-500/20",
                Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                    Path(:d => "M8 5v14l11-7z")
                ),
                "Run"
            )
        ),

        # Editor + Output
        Div(:class => "grid lg:grid-cols-2 gap-4",
            # Code editor
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Julia"),
                    Span(:class => "text-stone-500 text-xs", "Edit your code")
                ),
                Textarea(:id => "code-editor",
                         :class => "bg-stone-800 dark:bg-stone-900 p-4 rounded-b-xl text-sm text-stone-100 font-mono min-h-[400px] w-full resize-y focus:outline-none focus:ring-2 focus:ring-cyan-500 border-0",
                         :spellcheck => "false",
                         :placeholder => "Write Julia code here...",
                         DEFAULT_CODE
                )
            ),

            # Output panel
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Output"),
                    Span(:id => "status-indicator", :class => "text-amber-400 text-xs", "Ready")
                ),
                Div(:id => "output-panel",
                    :class => "bg-stone-900 dark:bg-black p-4 rounded-b-xl flex-1 min-h-[400px] font-mono overflow-auto",
                    Pre(:id => "output-content",
                        :class => "text-sm text-stone-400 whitespace-pre-wrap",
                        "Click 'Run' to compile and execute your Julia code.\n\nThe trimmed Julia compiler will run entirely in your browser."
                    )
                )
            )
        ),

        # Footer
        Div(:class => "mt-6 p-4 bg-stone-100 dark:bg-stone-800 rounded-xl",
            Div(:class => "flex items-start gap-3",
                Div(:class => "flex-shrink-0 w-8 h-8 bg-cyan-500 rounded-full flex items-center justify-center",
                    Span(:class => "text-white text-sm font-bold", "?")
                ),
                Div(
                    P(:class => "text-stone-700 dark:text-stone-200 font-medium text-sm",
                        "How it works"
                    ),
                    P(:class => "text-stone-500 dark:text-stone-400 text-xs mt-1",
                        "When the trimmed Julia runtime loads, your code is parsed by JuliaSyntax, type-inferred, and compiled to WebAssembly by WasmTarget.jl - all client-side. No server required."
                    )
                )
            )
        ),

        # Client-side JS
        Script(raw"""
            (function() {
                const editor = document.getElementById('code-editor');
                const runBtn = document.getElementById('run-btn');
                const output = document.getElementById('output-content');
                const status = document.getElementById('status-indicator');

                // Check for code passed from manual "Try in Playground" links
                const playgroundCode = localStorage.getItem('playground-code');
                if (playgroundCode && editor) {
                    editor.value = playgroundCode;
                    localStorage.removeItem('playground-code');
                    // Update output to show loaded code
                    output.innerHTML = '<span class="text-emerald-400">Code loaded from manual!</span>\n\nClick "Run" to compile and execute.';
                }

                runBtn.addEventListener('click', function() {
                    const code = editor.value;
                    status.textContent = 'Compiling...';
                    status.className = 'text-cyan-400 text-xs';
                    output.innerHTML = '<span class="text-cyan-400">Compiling...</span>\n\n';
                    output.innerHTML += '<span class="text-stone-500">// Your code:</span>\n';
                    output.innerHTML += '<span class="text-stone-300">' + escapeHtml(code.substring(0, 500)) + '</span>\n\n';
                    setTimeout(function() {
                        output.innerHTML += '<span class="text-amber-400">Trimmed Julia runtime loading...</span>\n';
                        output.innerHTML += '<span class="text-stone-500">The browser-based compiler requires Julia 1.12 trimming.</span>\n\n';
                        output.innerHTML += '<span class="text-stone-500">Status: In development</span>\n';
                        output.innerHTML += '<span class="text-stone-500">See: github.com/GroupTherapyOrg/WasmTarget.jl</span>';
                        status.textContent = 'Runtime loading...';
                        status.className = 'text-amber-400 text-xs';
                    }, 500);
                });

                function escapeHtml(text) {
                    const div = document.createElement('div');
                    div.textContent = text;
                    return div.innerHTML;
                }

                editor.addEventListener('keydown', function(e) {
                    if (e.key === 'Tab') {
                        e.preventDefault();
                        const start = this.selectionStart;
                        const end = this.selectionEnd;
                        this.value = this.value.substring(0, start) + '    ' + this.value.substring(end);
                        this.selectionStart = this.selectionEnd = start + 4;
                    }
                });
            })();
        """)
    )
end

"""
Interactive Julia Manual feature card for the home page.
"""
function ManualFeatureSection()
    Div(:class => "mt-16 mb-8",
        # Section header
        Div(:class => "text-center mb-8",
            H2(:class => "text-3xl font-bold text-stone-800 dark:text-stone-100",
                "Interactive Julia Manual"
            ),
            P(:class => "text-stone-500 dark:text-stone-400 mt-2 max-w-2xl mx-auto",
                "Learn Julia through hands-on examples that run real compiled code in your browser."
            )
        ),

        # Feature card
        A(:href => "manual/",
          :class => "group block max-w-4xl mx-auto p-8 bg-gradient-to-br from-cyan-50 to-teal-50 dark:from-cyan-900/20 dark:to-teal-900/20 rounded-2xl border border-cyan-200 dark:border-cyan-800 hover:border-cyan-400 dark:hover:border-cyan-600 hover:shadow-xl hover:shadow-cyan-500/10 transition-all duration-300",
            Div(:class => "flex flex-col md:flex-row items-center gap-8",
                # Icon
                Div(:class => "flex-shrink-0 w-20 h-20 bg-gradient-to-br from-cyan-400 to-teal-500 rounded-2xl flex items-center justify-center shadow-lg shadow-cyan-500/20 group-hover:scale-105 transition-transform duration-300",
                    Svg(:class => "w-10 h-10 text-white", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253")
                    )
                ),
                # Content
                Div(:class => "flex-1 text-center md:text-left",
                    H3(:class => "text-2xl font-bold text-stone-800 dark:text-stone-100 group-hover:text-cyan-600 dark:group-hover:text-cyan-400 transition-colors",
                        "10 Interactive Chapters"
                    ),
                    P(:class => "text-stone-600 dark:text-stone-400 mt-2 mb-4",
                        "From variables to multiple dispatch, each chapter features live code examples compiled to WebAssembly. Click, edit, and see results instantly - all running in your browser."
                    ),
                    # Chapter tags
                    Div(:class => "flex flex-wrap justify-center md:justify-start gap-2",
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-cyan-100 dark:bg-cyan-900/40 text-cyan-700 dark:text-cyan-300", "Variables"),
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-cyan-100 dark:bg-cyan-900/40 text-cyan-700 dark:text-cyan-300", "Functions"),
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-cyan-100 dark:bg-cyan-900/40 text-cyan-700 dark:text-cyan-300", "Control Flow"),
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-cyan-100 dark:bg-cyan-900/40 text-cyan-700 dark:text-cyan-300", "Types"),
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-cyan-100 dark:bg-cyan-900/40 text-cyan-700 dark:text-cyan-300", "Arrays"),
                        Span(:class => "px-3 py-1 text-xs rounded-full bg-stone-200 dark:bg-stone-700 text-stone-600 dark:text-stone-400", "+5 more")
                    )
                ),
                # Arrow
                Div(:class => "flex-shrink-0 hidden md:block",
                    Svg(:class => "w-8 h-8 text-cyan-400 group-hover:text-cyan-500 group-hover:translate-x-2 transition-all duration-300",
                        :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M9 5l7 7-7 7")
                    )
                )
            )
        ),

        # WasmTarget.jl note
        Div(:class => "max-w-4xl mx-auto mt-4 text-center",
            P(:class => "text-sm text-stone-500 dark:text-stone-500",
                "Examples run real Julia code compiled to WebAssembly by WasmTarget.jl. ",
                A(:href => "features/", :class => "text-cyan-500 hover:text-cyan-600 dark:text-cyan-400 dark:hover:text-cyan-300 underline", "See supported features →")
            )
        )
    )
end

function Index()
    Layout(
        Div(:class => "py-8",
            # Header
            Div(:class => "text-center mb-8",
                H1(:class => "text-4xl font-bold text-stone-800 dark:text-stone-100",
                    "Julia → WebAssembly"
                ),
                P(:class => "text-stone-500 dark:text-stone-400 mt-2",
                    "Write Julia. Compile to WASM. Run in the browser."
                )
            ),

            # Main Playground
            JuliaPlayground(),

            # Interactive Julia Manual Section
            ManualFeatureSection()
        )
    )
end

# Export
Index
