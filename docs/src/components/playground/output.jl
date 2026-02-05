# Output.jl - Playground output display component
#
# Displays execution results from the playground with:
# - Visual feedback for loading/executing states
# - Error display for compilation and runtime errors
# - Support for different output types (text, numeric, DOM)
# - Integration with the PlaygroundEngine
#
# Story: PLAYGROUND-022

# Include dependencies at module level
include("../demos.jl")
include("examples.jl")

"""
Output state enumeration for visual feedback.
"""
const OUTPUT_STATES = Dict(
    "idle" => (color = "warm-500", text = "Ready"),
    "loading" => (color = "yellow-500", text = "Loading..."),
    "running" => (color = "blue-500", text = "Running"),
    "success" => (color = "green-500", text = "Complete"),
    "error" => (color = "red-500", text = "Error")
)

"""
PlaygroundOutput component - the main output display wrapper.

Wraps the PlaygroundEngine with additional UI:
- Header with status indicator and controls
- Output area with proper styling
- Error message display area
- Console/log output area

Arguments:
- `initial_example::String` - The example to show initially (default: "arithmetic")
- `show_console::Bool` - Whether to show console output area (default: false for MVP)

Usage:
    PlaygroundOutput(initial_example = "arithmetic")
"""
function PlaygroundOutput(;
    initial_example::String = "arithmetic",
    show_console::Bool = false
)
    Div(:class => "flex flex-col h-full border border-warm-700 rounded-xl overflow-hidden",
        :id => "playground-output",

        # Header bar with status
        Div(:class => "flex items-center justify-between px-4 py-2 bg-warm-700 dark:bg-warm-800",
            # Title and output type indicator
            Div(:class => "flex items-center gap-3",
                Span(:class => "text-warm-300 text-sm font-medium", "Output"),
                # Output type badge (changes based on what's displayed)
                Span(:id => "output-type-badge",
                    :class => "px-2 py-0.5 text-xs rounded-full bg-warm-600 text-warm-300",
                    "Interactive Demo"
                )
            ),
            # Status and controls
            Div(:class => "flex items-center gap-3",
                # Execution time display
                Span(:id => "output-exec-time",
                    :class => "text-warm-500 text-xs hidden",
                    ""
                ),
                # Status indicator
                Div(:id => "output-status",
                    :class => "flex items-center gap-2",
                    # Status dot
                    Span(:id => "output-status-dot",
                        :class => "w-2 h-2 rounded-full bg-green-500",
                        ""
                    ),
                    # Status text
                    Span(:id => "output-status-text",
                        :class => "text-warm-400 text-xs",
                        "Ready"
                    )
                ),
                # Refresh button
                Button(:id => "output-refresh-btn",
                    :class => "text-warm-400 hover:text-white p-1 transition-colors",
                    :title => "Reset output",
                    Svg(:class => "w-4 h-4", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                            :d => "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                        )
                    )
                )
            )
        ),

        # Main output content area
        Div(:class => "flex-1 min-h-[300px] relative",

            # Loading overlay (hidden by default)
            Div(:id => "output-loading-overlay",
                :class => "absolute inset-0 bg-warm-900/80 flex items-center justify-center z-20 hidden",
                # Spinner
                Div(:class => "flex flex-col items-center gap-3",
                    Svg(:class => "w-8 h-8 text-accent-500 animate-spin", :fill => "none", :viewBox => "0 0 24 24",
                        Circle(:class => "opacity-25", :cx => "12", :cy => "12", :r => "10",
                               :stroke => "currentColor", :stroke_width => "4"),
                        Path(:class => "opacity-75", :fill => "currentColor",
                             :d => "M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z")
                    ),
                    Span(:class => "text-warm-300 text-sm", "Loading example...")
                )
            ),

            # Error display area (hidden by default)
            Div(:id => "output-error-area",
                :class => "hidden",
                Div(:class => "p-4 bg-red-900/30 border-l-4 border-red-500",
                    Div(:class => "flex items-start gap-3",
                        # Error icon
                        Svg(:class => "w-5 h-5 text-red-500 mt-0.5 flex-shrink-0", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                :d => "M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                        ),
                        # Error content
                        Div(:class => "flex-1",
                            Div(:id => "output-error-title",
                                :class => "text-red-400 font-medium text-sm",
                                "Error"
                            ),
                            Div(:id => "output-error-message",
                                :class => "text-warm-400 text-xs mt-1 font-mono whitespace-pre-wrap",
                                ""
                            )
                        ),
                        # Dismiss button
                        Button(:id => "output-error-dismiss",
                            :class => "text-warm-500 hover:text-white p-1",
                            Svg(:class => "w-4 h-4", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                    :d => "M6 18L18 6M6 6l12 12")
                            )
                        )
                    )
                )
            ),

            # Demo/Island output area
            Div(:id => "output-demo-area",
                :class => "p-4 bg-warm-800 dark:bg-warm-900 min-h-[250px]",

                # Arithmetic demo
                Div(:id => "demo-arithmetic",
                    :class => initial_example == "arithmetic" ? "" : "hidden",
                    ArithmeticDemo
                ),

                # Factorial demo (RecursionDemo)
                Div(:id => "demo-factorial",
                    :class => initial_example == "factorial" ? "" : "hidden",
                    RecursionDemo
                ),

                # Sum to N demo (LoopDemo)
                Div(:id => "demo-sum_to_n",
                    :class => initial_example == "sum_to_n" ? "" : "hidden",
                    LoopDemo
                ),

                # Sign demo (ControlFlowDemo)
                Div(:id => "demo-sign",
                    :class => initial_example == "sign" ? "" : "hidden",
                    ControlFlowDemo
                ),

                # Counter placeholder
                Div(:id => "demo-counter",
                    :class => initial_example == "counter" ? "" : "hidden",
                    Div(:class => "text-center p-8 bg-warm-50 dark:bg-warm-700 rounded-xl shadow-lg",
                        Div(:class => "text-warm-400 text-sm mb-4",
                            "Reactive Counter Demo"
                        ),
                        Div(:class => "text-warm-500 text-xs",
                            "The counter example demonstrates Therapy.jl signals. ",
                            "Full interactive version coming soon."
                        )
                    )
                ),

                # Unknown/fallback placeholder
                Div(:id => "demo-unknown",
                    :class => "hidden",
                    Div(:class => "text-center p-8 bg-warm-700 rounded-lg",
                        Svg(:class => "w-12 h-12 mx-auto mb-3 text-warm-500", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                :d => "M9.172 16.172a4 4 0 015.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                        ),
                        Div(:class => "text-warm-400 text-sm mb-2", "Example Not Available"),
                        Div(:class => "text-warm-500 text-xs",
                            "This example doesn't have an interactive demo yet."
                        )
                    )
                )
            ),

            # Console output area (optional, for Phase 2)
            show_console ?
                Div(:id => "output-console-area",
                    :class => "border-t border-warm-700 bg-warm-900 p-4 max-h-[150px] overflow-auto",
                    Div(:class => "flex items-center justify-between mb-2",
                        Span(:class => "text-warm-500 text-xs uppercase tracking-wider", "Console"),
                        Button(:id => "output-console-clear",
                            :class => "text-warm-500 hover:text-white text-xs",
                            "Clear"
                        )
                    ),
                    Pre(:id => "output-console-content",
                        :class => "text-warm-400 text-xs font-mono",
                        ""
                    )
                ) : nothing
        ),

        # Footer with capabilities hint
        Div(:class => "px-4 py-2 bg-warm-800 dark:bg-warm-850 border-t border-warm-700",
            Div(:class => "flex items-center justify-between",
                Span(:class => "text-warm-500 text-xs",
                    "Pre-compiled WebAssembly demos • Real Julia compiled by WasmTarget.jl"
                ),
                # Info link
                A(:href => "#capabilities",
                    :class => "text-accent-500 hover:text-accent-400 text-xs",
                    "What can I run?"
                )
            )
        ),

        # Client-side JavaScript for output management
        Script("""
            (function() {
                // DOM elements
                const outputArea = document.getElementById('playground-output');
                const statusDot = document.getElementById('output-status-dot');
                const statusText = document.getElementById('output-status-text');
                const execTime = document.getElementById('output-exec-time');
                const typeBadge = document.getElementById('output-type-badge');
                const loadingOverlay = document.getElementById('output-loading-overlay');
                const errorArea = document.getElementById('output-error-area');
                const errorTitle = document.getElementById('output-error-title');
                const errorMessage = document.getElementById('output-error-message');
                const errorDismiss = document.getElementById('output-error-dismiss');
                const refreshBtn = document.getElementById('output-refresh-btn');
                const demoArea = document.getElementById('output-demo-area');
                const consoleArea = document.getElementById('output-console-area');
                const consoleContent = document.getElementById('output-console-content');
                const consoleClear = document.getElementById('output-console-clear');

                // All demo IDs
                const demoIds = ['arithmetic', 'factorial', 'sum_to_n', 'sign', 'counter'];

                // Current state
                let currentExample = '$(initial_example)';
                let startTime = null;

                // State management
                const states = {
                    idle: { color: 'bg-warm-500', text: 'Ready' },
                    loading: { color: 'bg-yellow-500 animate-pulse', text: 'Loading...' },
                    running: { color: 'bg-blue-500 animate-pulse', text: 'Running' },
                    success: { color: 'bg-green-500', text: 'Complete' },
                    error: { color: 'bg-red-500', text: 'Error' }
                };

                function updateStatus(state) {
                    const config = states[state] || states.idle;
                    if (statusDot) {
                        statusDot.className = 'w-2 h-2 rounded-full ' + config.color;
                    }
                    if (statusText) {
                        statusText.textContent = config.text;
                    }
                }

                function showLoading() {
                    if (loadingOverlay) {
                        loadingOverlay.classList.remove('hidden');
                    }
                    updateStatus('loading');
                    startTime = performance.now();
                }

                function hideLoading() {
                    if (loadingOverlay) {
                        loadingOverlay.classList.add('hidden');
                    }
                    // Show execution time
                    if (startTime && execTime) {
                        const elapsed = (performance.now() - startTime).toFixed(0);
                        execTime.textContent = elapsed + 'ms';
                        execTime.classList.remove('hidden');
                        startTime = null;
                    }
                }

                function showError(title, message) {
                    if (errorArea) {
                        errorArea.classList.remove('hidden');
                    }
                    if (errorTitle) {
                        errorTitle.textContent = title;
                    }
                    if (errorMessage) {
                        errorMessage.textContent = message;
                    }
                    updateStatus('error');
                }

                function hideError() {
                    if (errorArea) {
                        errorArea.classList.add('hidden');
                    }
                }

                function switchDemo(exampleId) {
                    // Hide all demos
                    demoIds.forEach(id => {
                        const demo = document.getElementById('demo-' + id);
                        if (demo) demo.classList.add('hidden');
                    });

                    // Also hide unknown fallback
                    const unknown = document.getElementById('demo-unknown');
                    if (unknown) unknown.classList.add('hidden');

                    // Show selected demo
                    const selected = document.getElementById('demo-' + exampleId);
                    if (selected) {
                        selected.classList.remove('hidden');
                        currentExample = exampleId;
                        updateStatus('success');

                        // Update type badge based on example
                        if (typeBadge) {
                            const badges = {
                                'arithmetic': 'Numeric Demo',
                                'factorial': 'Recursion Demo',
                                'sum_to_n': 'Loop Demo',
                                'sign': 'Control Flow Demo',
                                'counter': 'Reactive Demo'
                            };
                            typeBadge.textContent = badges[exampleId] || 'Interactive Demo';
                        }
                    } else {
                        // Show unknown fallback
                        if (unknown) unknown.classList.remove('hidden');
                        updateStatus('error');
                    }

                    hideLoading();
                }

                function logToConsole(message, type = 'log') {
                    if (!consoleContent) return;

                    const line = document.createElement('div');
                    line.className = type === 'error' ? 'text-red-400' :
                                    type === 'warn' ? 'text-yellow-400' : 'text-warm-400';
                    line.textContent = '> ' + message;
                    consoleContent.appendChild(line);
                    consoleContent.scrollTop = consoleContent.scrollHeight;
                }

                // Event listeners

                // Listen for example selection from ExampleSelector
                window.addEventListener('playground-select-example', function(e) {
                    if (e.detail && e.detail.exampleId) {
                        hideError();
                        showLoading();
                        // Brief delay to show loading state
                        setTimeout(() => {
                            switchDemo(e.detail.exampleId);
                            // Dispatch event for other components
                            window.dispatchEvent(new CustomEvent('playground-example-changed', {
                                detail: { exampleId: e.detail.exampleId }
                            }));
                        }, 100);
                    }
                });

                // Listen for code changes (Phase 2: server compilation)
                window.addEventListener('playground-code-changed', function(e) {
                    // In MVP, we just note that custom code can't run yet
                    // Phase 2 will send code to server for compilation
                });

                // Error dismiss
                if (errorDismiss) {
                    errorDismiss.addEventListener('click', hideError);
                }

                // Refresh button - reset current demo
                if (refreshBtn) {
                    refreshBtn.addEventListener('click', function() {
                        hideError();
                        showLoading();
                        setTimeout(() => {
                            switchDemo(currentExample);
                        }, 100);
                    });
                }

                // Console clear
                if (consoleClear) {
                    consoleClear.addEventListener('click', function() {
                        if (consoleContent) {
                            consoleContent.innerHTML = '';
                        }
                    });
                }

                // Expose functions globally for other components
                window.playgroundOutput = {
                    switchDemo: switchDemo,
                    showError: showError,
                    hideError: hideError,
                    showLoading: showLoading,
                    hideLoading: hideLoading,
                    logToConsole: logToConsole,
                    updateStatus: updateStatus
                };

                // Initial state
                updateStatus('success');

            })();
        """)
    )
end

"""
ErrorDisplay component - shows compilation or runtime errors.

A standalone error display component that can be used outside
the main output area.

Arguments:
- `title::String` - Error title (e.g., "Compilation Error")
- `message::String` - Detailed error message
- `dismissable::Bool` - Whether error can be dismissed (default: true)
"""
function ErrorDisplay(;
    title::String = "Error",
    message::String = "",
    dismissable::Bool = true
)
    Div(:class => "rounded-lg bg-red-900/30 border border-red-700/50 overflow-hidden",
        Div(:class => "px-4 py-3",
            # Header
            Div(:class => "flex items-center justify-between mb-2",
                Div(:class => "flex items-center gap-2",
                    # Error icon
                    Svg(:class => "w-5 h-5 text-red-500", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                            :d => "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z")
                    ),
                    Span(:class => "text-red-400 font-medium", title)
                ),
                # Dismiss button
                dismissable ?
                    Button(:class => "text-warm-500 hover:text-white p-1",
                        :onclick => "this.closest('.rounded-lg').remove()",
                        Svg(:class => "w-4 h-4", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                :d => "M6 18L18 6M6 6l12 12")
                        )
                    ) : nothing
            ),
            # Error message
            Pre(:class => "text-warm-400 text-xs font-mono whitespace-pre-wrap bg-warm-900/50 p-3 rounded",
                message
            )
        )
    )
end

"""
LoadingSpinner component - animated loading indicator.

Arguments:
- `size::String` - Size class (default: "w-8 h-8")
- `text::String` - Loading text to display (default: "Loading...")
"""
function LoadingSpinner(;
    size::String = "w-8 h-8",
    text::String = "Loading..."
)
    Div(:class => "flex flex-col items-center gap-3",
        Svg(:class => "$(size) text-accent-500 animate-spin", :fill => "none", :viewBox => "0 0 24 24",
            Circle(:class => "opacity-25", :cx => "12", :cy => "12", :r => "10",
                   :stroke => "currentColor", :stroke_width => "4"),
            Path(:class => "opacity-75", :fill => "currentColor",
                 :d => "M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z")
        ),
        Span(:class => "text-warm-300 text-sm", text)
    )
end

"""
OutputTypeDisplay component - renders different output types appropriately.

Handles text, numeric, and structured output types with appropriate formatting.

Arguments:
- `value` - The value to display
- `type::String` - Type hint ("text", "number", "struct", "array", "dom")
"""
function OutputTypeDisplay(; value, type::String = "auto")
    # Determine type if auto
    actual_type = if type == "auto"
        if value isa Number
            "number"
        elseif value isa AbstractString
            "text"
        elseif value isa AbstractArray
            "array"
        else
            "text"
        end
    else
        type
    end

    Div(:class => "p-4 bg-warm-800 rounded-lg",
        if actual_type == "number"
            # Numeric display - large centered number
            Div(:class => "text-center",
                Span(:class => "text-accent-400 font-mono text-4xl font-bold", string(value))
            )
        elseif actual_type == "array"
            # Array display - formatted list
            Div(:class => "font-mono text-sm",
                Pre(:class => "text-warm-300 whitespace-pre-wrap",
                    string(value)
                )
            )
        elseif actual_type == "struct"
            # Struct display - property list
            Div(:class => "font-mono text-sm space-y-1",
                Pre(:class => "text-warm-300",
                    string(value)
                )
            )
        else
            # Default text display
            Div(:class => "text-warm-300",
                string(value)
            )
        end
    )
end

"""
CapabilitiesPanel component - explains what the playground can do.

Shown below the output area to help users understand capabilities.
"""
function CapabilitiesPanel()
    Div(:id => "capabilities",
        :class => "mt-6 p-6 bg-warm-800 rounded-xl border border-warm-700",

        # Header
        Div(:class => "flex items-center gap-2 mb-4",
            Svg(:class => "w-5 h-5 text-accent-500", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                    :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
            ),
            Span(:class => "text-warm-200 font-medium", "What Can I Run?")
        ),

        # Capabilities grid
        Div(:class => "grid md:grid-cols-2 gap-4",
            # Supported
            Div(:class => "space-y-2",
                Span(:class => "text-green-400 text-sm font-medium", "Supported Features"),
                Ul(:class => "text-warm-400 text-sm space-y-1 ml-4",
                    Li("Arithmetic operations (add, subtract, multiply, divide)"),
                    Li("Recursive functions (factorial, fibonacci)"),
                    Li("Loops (while, for)"),
                    Li("Conditionals (if/elseif/else)"),
                    Li("Structs with typed fields"),
                    Li("Arrays (1D and 2D)"),
                    Li("Reactive UI with signals")
                )
            ),
            # Not supported
            Div(:class => "space-y-2",
                Span(:class => "text-red-400 text-sm font-medium", "Current Limitations"),
                Ul(:class => "text-warm-400 text-sm space-y-1 ml-4",
                    Li("Multiple dispatch (Julia's core feature)"),
                    Li("Dynamic typing / type inference at runtime"),
                    Li("String operations (limited support)"),
                    Li("Exception handling (try/catch)"),
                    Li("Module imports"),
                    Li("Macros"),
                    Li("File I/O")
                )
            )
        ),

        # Note about MVP
        Div(:class => "mt-4 p-3 bg-warm-900/30 rounded-lg border border-warm-700/50",
            Div(:class => "flex items-start gap-2",
                Svg(:class => "w-4 h-4 text-accent-400 mt-0.5 flex-shrink-0", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                        :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                ),
                Span(:class => "text-warm-300 text-xs",
                    "This playground shows pre-compiled examples. Custom code execution will be available in a future update with server-side compilation."
                )
            )
        )
    )
end
