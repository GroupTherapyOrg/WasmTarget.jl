# Engine.jl - Playground execution engine
#
# For MVP (pre-compiled examples approach), the "engine" is the mapping
# of example IDs to their pre-compiled island components from Demos.jl.
#
# The engine provides:
# - Example ID → Island component mapping
# - Selection rendering (show/hide based on active example)
# - Error handling for missing examples
# - State management for selected example
#
# Story: PLAYGROUND-021

include("../demos.jl")
include("examples.jl")

"""
Mapping of example IDs to their pre-compiled island components.
These islands are defined in Demos.jl and compiled to WASM.
"""
const EXAMPLE_ISLANDS = Dict{String, Any}(
    "arithmetic" => ArithmeticDemo,
    "factorial"  => RecursionDemo,
    "sum_to_n"   => LoopDemo,
    "sign"       => ControlFlowDemo,
    "counter"    => nothing  # Counter uses ControlFlowDemo as closest match for MVP
)

"""
Get the island component for a given example ID.
Returns nothing if no matching island exists.

Arguments:
- `example_id::String` - The ID of the example to load

Returns:
- The island component if found, nothing otherwise
"""
function get_island_for_example(example_id::String)
    return get(EXAMPLE_ISLANDS, example_id, nothing)
end

"""
Check if an example has a corresponding island implementation.

Arguments:
- `example_id::String` - The ID of the example to check

Returns:
- true if the example has an island, false otherwise
"""
function has_island(example_id::String)
    island = get(EXAMPLE_ISLANDS, example_id, nothing)
    return island !== nothing
end

"""
Get all example IDs that have working islands.

Returns:
- Vector of example IDs with implemented islands
"""
function examples_with_islands()
    return [id for (id, island) in EXAMPLE_ISLANDS if island !== nothing]
end

"""
PlaygroundEngine component - renders the selected example's output.

This is a server component that conditionally renders the appropriate
island based on the selected example. Uses client-side JS to handle
example switching via custom events.

Arguments:
- `initial_example::String` - The example ID to show initially (default: "arithmetic")

Usage:
    PlaygroundEngine(initial_example = "arithmetic")
"""
function PlaygroundEngine(; initial_example::String = "arithmetic")
    # Get the initial example data
    example = get_example(initial_example)

    Div(:class => "flex flex-col h-full",
        # Header bar
        Div(:class => "flex items-center justify-between px-4 py-2 bg-warm-700 dark:bg-warm-900 rounded-t-xl",
            Span(:class => "text-warm-300 text-sm font-medium", "Output"),
            # Run status indicator
            Div(:id => "engine-status",
                :class => "flex items-center gap-2",
                Span(:class => "w-2 h-2 rounded-full bg-green-500", ""),
                Span(:class => "text-warm-400 text-xs", "Ready")
            )
        ),

        # Output area - contains all example islands (show/hide based on selection)
        Div(:class => "flex-1 bg-warm-800 dark:bg-warm-900 p-4 overflow-auto rounded-b-xl min-h-[300px]",
            :id => "engine-output",

            # Arithmetic demo
            Div(:id => "example-arithmetic",
                :class => initial_example == "arithmetic" ? "" : "hidden",
                ArithmeticDemo
            ),

            # Factorial demo (uses RecursionDemo)
            Div(:id => "example-factorial",
                :class => initial_example == "factorial" ? "" : "hidden",
                RecursionDemo
            ),

            # Sum to N demo (uses LoopDemo)
            Div(:id => "example-sum_to_n",
                :class => initial_example == "sum_to_n" ? "" : "hidden",
                LoopDemo
            ),

            # Sign demo (uses ControlFlowDemo)
            Div(:id => "example-sign",
                :class => initial_example == "sign" ? "" : "hidden",
                ControlFlowDemo
            ),

            # Counter demo - placeholder until we have a dedicated counter island
            Div(:id => "example-counter",
                :class => initial_example == "counter" ? "" : "hidden",
                Div(:class => "text-center p-8",
                    Div(:class => "text-warm-400 text-sm mb-4",
                        "The Counter example demonstrates Therapy.jl signals."
                    ),
                    Div(:class => "text-warm-500 text-xs",
                        "Interactive counter coming in a future update."
                    )
                )
            ),

            # Fallback for unknown examples
            Div(:id => "example-unknown",
                :class => "hidden",
                Div(:class => "text-center p-8",
                    Div(:class => "text-amber-500 text-sm mb-2",
                        "Example not available"
                    ),
                    Div(:class => "text-warm-500 text-xs",
                        "This example doesn't have an interactive demo yet."
                    )
                )
            )
        ),

        # Client-side JS for example switching
        Script("""
            (function() {
                const output = document.getElementById('engine-output');
                const status = document.getElementById('engine-status');
                const statusDot = status ? status.querySelector('span:first-child') : null;
                const statusText = status ? status.querySelector('span:last-child') : null;

                // All example container IDs
                const exampleIds = ['arithmetic', 'factorial', 'sum_to_n', 'sign', 'counter'];

                // Function to switch to a different example
                function switchExample(exampleId) {
                    // Hide all examples
                    exampleIds.forEach(id => {
                        const el = document.getElementById('example-' + id);
                        if (el) el.classList.add('hidden');
                    });

                    // Also hide unknown fallback
                    const unknown = document.getElementById('example-unknown');
                    if (unknown) unknown.classList.add('hidden');

                    // Show the selected example
                    const selected = document.getElementById('example-' + exampleId);
                    if (selected) {
                        selected.classList.remove('hidden');
                        updateStatus('ready', 'Ready');
                    } else {
                        // Show fallback for unknown example
                        if (unknown) unknown.classList.remove('hidden');
                        updateStatus('error', 'No demo');
                    }

                    // Dispatch event to notify other components
                    window.dispatchEvent(new CustomEvent('playground-example-changed', {
                        detail: { exampleId: exampleId }
                    }));
                }

                // Update status indicator
                function updateStatus(state, text) {
                    if (!statusDot || !statusText) return;

                    statusText.textContent = text;
                    statusDot.className = 'w-2 h-2 rounded-full ';

                    switch(state) {
                        case 'ready':
                            statusDot.className += 'bg-green-500';
                            break;
                        case 'loading':
                            statusDot.className += 'bg-yellow-500 animate-pulse';
                            break;
                        case 'error':
                            statusDot.className += 'bg-red-500';
                            break;
                        default:
                            statusDot.className += 'bg-warm-500';
                    }
                }

                // Listen for example selection events from selector
                window.addEventListener('playground-select-example', function(e) {
                    if (e.detail && e.detail.exampleId) {
                        updateStatus('loading', 'Loading...');
                        // Small delay to show loading state
                        setTimeout(() => {
                            switchExample(e.detail.exampleId);
                        }, 50);
                    }
                });

                // Listen for code changes (from editor, if user types)
                window.addEventListener('playground-code-changed', function(e) {
                    // In MVP, we show a message that custom code can't be run
                    // Phase 2 will add server compilation here
                });

                // Expose switch function globally for direct calls
                window.playgroundSwitchExample = switchExample;

            })();
        """)
    )
end

"""
ExampleSelector component - dropdown/tabs for selecting examples.

Renders a selector UI that allows users to pick from available examples.
Dispatches 'playground-select-example' events when selection changes.

Arguments:
- `initial_example::String` - The initially selected example ID
- `show_categories::Bool` - Whether to group by category (default: true)

Usage:
    ExampleSelector(initial_example = "arithmetic")
"""
function ExampleSelector(;
    initial_example::String = "arithmetic",
    show_categories::Bool = true
)
    Div(:class => "flex flex-wrap items-center gap-4",
        # Label
        Span(:class => "text-warm-400 text-sm", "Examples:"),

        # Category tabs (if grouped)
        if show_categories
            Div(:class => "flex flex-wrap gap-2",
                :id => "example-selector",

                # Numeric category
                Div(:class => "flex items-center",
                    Span(:class => "text-warm-500 text-xs mr-2", "Numeric"),
                    Button(:class => initial_example == "arithmetic" ?
                        "px-3 py-1 rounded-full text-xs bg-accent-500 text-white" :
                        "px-3 py-1 rounded-full text-xs bg-warm-700 text-warm-300 hover:bg-warm-600",
                        :data_example => "arithmetic",
                        :onclick => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: 'arithmetic'}}))",
                        "Arithmetic"
                    ),
                    Button(:class => initial_example == "factorial" ?
                        "px-3 py-1 rounded-full text-xs bg-accent-500 text-white ml-1" :
                        "px-3 py-1 rounded-full text-xs bg-warm-700 text-warm-300 hover:bg-warm-600 ml-1",
                        :data_example => "factorial",
                        :onclick => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: 'factorial'}}))",
                        "Factorial"
                    ),
                    Button(:class => initial_example == "sum_to_n" ?
                        "px-3 py-1 rounded-full text-xs bg-accent-500 text-white ml-1" :
                        "px-3 py-1 rounded-full text-xs bg-warm-700 text-warm-300 hover:bg-warm-600 ml-1",
                        :data_example => "sum_to_n",
                        :onclick => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: 'sum_to_n'}}))",
                        "Sum to N"
                    )
                ),

                # Divider
                Span(:class => "text-warm-600 mx-2", "|"),

                # Control Flow category
                Div(:class => "flex items-center",
                    Span(:class => "text-warm-500 text-xs mr-2", "Control Flow"),
                    Button(:class => initial_example == "sign" ?
                        "px-3 py-1 rounded-full text-xs bg-accent-500 text-white" :
                        "px-3 py-1 rounded-full text-xs bg-warm-700 text-warm-300 hover:bg-warm-600",
                        :data_example => "sign",
                        :onclick => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: 'sign'}}))",
                        "Sign"
                    )
                ),

                # Divider
                Span(:class => "text-warm-600 mx-2", "|"),

                # UI Patterns category
                Div(:class => "flex items-center",
                    Span(:class => "text-warm-500 text-xs mr-2", "UI"),
                    Button(:class => initial_example == "counter" ?
                        "px-3 py-1 rounded-full text-xs bg-accent-500 text-white" :
                        "px-3 py-1 rounded-full text-xs bg-warm-700 text-warm-300 hover:bg-warm-600",
                        :data_example => "counter",
                        :onclick => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: 'counter'}}))",
                        "Counter"
                    )
                )
            )
        else
            # Simple dropdown
            Select(:class => "bg-warm-700 text-warm-100 rounded px-3 py-1 text-sm",
                :id => "example-dropdown",
                :onchange => "window.dispatchEvent(new CustomEvent('playground-select-example', {detail: {exampleId: this.value}}))",
                Option(:value => "arithmetic", :selected => initial_example == "arithmetic", "Arithmetic Operations"),
                Option(:value => "factorial", :selected => initial_example == "factorial", "Factorial (Recursion)"),
                Option(:value => "sum_to_n", :selected => initial_example == "sum_to_n", "Sum 1 to N (Loop)"),
                Option(:value => "sign", :selected => initial_example == "sign", "Sign Function"),
                Option(:value => "counter", :selected => initial_example == "counter", "Reactive Counter")
            )
        end,

        # Client-side JS for updating active state
        Script("""
            (function() {
                const selector = document.getElementById('example-selector');
                if (!selector) return;

                // Update button styles when example changes
                window.addEventListener('playground-example-changed', function(e) {
                    const buttons = selector.querySelectorAll('button');
                    buttons.forEach(btn => {
                        const isActive = btn.dataset.example === e.detail.exampleId;
                        if (isActive) {
                            btn.className = btn.className
                                .replace('bg-warm-700', 'bg-accent-500')
                                .replace('text-warm-300', 'text-white')
                                .replace('hover:bg-warm-600', '');
                        } else {
                            btn.className = btn.className
                                .replace('bg-accent-500', 'bg-warm-700')
                                .replace('text-white', 'text-warm-300');
                            if (!btn.className.includes('hover:bg-warm-600')) {
                                btn.className += ' hover:bg-warm-600';
                            }
                        }
                    });
                });

                // Also update dropdown if present
                const dropdown = document.getElementById('example-dropdown');
                if (dropdown) {
                    window.addEventListener('playground-example-changed', function(e) {
                        dropdown.value = e.detail.exampleId;
                    });
                }
            })();
        """)
    )
end

"""
Get a description of engine capabilities for display.
"""
function engine_capabilities_description()
    return """
    The playground engine runs pre-compiled WebAssembly examples directly in your browser.

    Currently available demos:
    • Arithmetic: Add, multiply, divide with reactive UI
    • Factorial: Recursive computation
    • Sum to N: Loop-based summation
    • Sign: Conditional branching
    • Counter: Reactive signals (coming soon)

    Each demo is real Julia code compiled to WebAssembly by WasmTarget.jl.
    """
end
