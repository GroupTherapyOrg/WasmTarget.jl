# ManualLayout.jl - Layout component for manual pages
#
# Provides sidebar navigation, breadcrumbs, and prev/next links
# for the interactive Julia manual chapters.
# Follows the same cyan/teal color scheme as Layout.jl

# Manual chapters in order (id, title, description)
const MANUAL_CHAPTERS = [
    ("variables", "Variables", "Naming, assignment, types"),
    ("integers-floats", "Integers & Floats", "Numeric types and literals"),
    ("math-operations", "Math Operations", "Arithmetic, comparison, bitwise"),
    ("strings", "Strings", "Literals, concatenation, comparison"),
    ("functions", "Functions", "Definition, arguments, recursion"),
    ("control-flow", "Control Flow", "if/else, loops, short-circuit"),
    ("types", "Types (Structs)", "Composite types, mutable structs"),
    ("methods", "Methods", "Multiple dispatch"),
    ("arrays", "Arrays", "Vectors, matrices, indexing"),
    ("tuples", "Tuples", "Creation, indexing, destructuring"),
]

# Chapter relationships for "See Also" cross-references
# Maps chapter id to list of related chapter ids (conceptually related, not sequential)
const CHAPTER_RELATIONS = Dict(
    "variables" => ["integers-floats", "types"],
    "integers-floats" => ["variables", "math-operations"],
    "math-operations" => ["integers-floats", "control-flow"],
    "strings" => ["arrays", "variables"],
    "functions" => ["control-flow", "methods", "tuples"],
    "control-flow" => ["functions", "math-operations"],
    "types" => ["variables", "methods", "arrays"],
    "methods" => ["functions", "types"],
    "arrays" => ["tuples", "types", "control-flow"],
    "tuples" => ["arrays", "functions", "types"],
)

"""
Get the index of a chapter by its id. Returns nothing if not found.
"""
function get_chapter_index(chapter_id::String)
    for (i, (id, _, _)) in enumerate(MANUAL_CHAPTERS)
        if id == chapter_id
            return i
        end
    end
    return nothing
end

"""
Get previous and next chapter info for navigation.
Returns (prev, next) where each is (id, title) or nothing.
"""
function get_chapter_nav(chapter_id::String)
    idx = get_chapter_index(chapter_id)
    if idx === nothing
        return (nothing, nothing)
    end

    prev_chapter = idx > 1 ? (MANUAL_CHAPTERS[idx-1][1], MANUAL_CHAPTERS[idx-1][2]) : nothing
    next_chapter = idx < length(MANUAL_CHAPTERS) ? (MANUAL_CHAPTERS[idx+1][1], MANUAL_CHAPTERS[idx+1][2]) : nothing

    return (prev_chapter, next_chapter)
end

"""
Get chapter info (id, title, description) by id. Returns nothing if not found.
"""
function get_chapter_info(chapter_id::String)
    for (id, title, desc) in MANUAL_CHAPTERS
        if id == chapter_id
            return (id, title, desc)
        end
    end
    return nothing
end

"""
Get related chapters for a given chapter id.
Returns vector of (id, title, description) tuples.
"""
function get_related_chapters(chapter_id::String)
    related_ids = get(CHAPTER_RELATIONS, chapter_id, String[])
    return [get_chapter_info(id) for id in related_ids if get_chapter_info(id) !== nothing]
end

"""
Sidebar navigation item with active state highlighting.
"""
function SidebarItem(id, title, description, is_active)
    base_classes = "block px-3 py-2 rounded-lg text-sm transition-colors"
    active_classes = is_active ?
        "bg-cyan-100 dark:bg-cyan-900/30 text-cyan-700 dark:text-cyan-300 font-medium" :
        "text-stone-600 dark:text-stone-400 hover:bg-stone-100 dark:hover:bg-stone-700"

    A(:href => "$id/",
      :class => "$base_classes $active_classes",
        Div(:class => "flex items-center justify-between",
            Span(title),
            is_active ? Span(:class => "text-cyan-500",
                Svg(:class => "w-4 h-4", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M9 5l7 7-7 7")
                )
            ) : nothing
        ),
        Span(:class => "text-xs text-stone-400 dark:text-stone-500 block mt-0.5", description)
    )
end

"""
Breadcrumb navigation component.
"""
function Breadcrumb(chapter_title)
    Nav(:class => "text-sm mb-6", :aria_label => "Breadcrumb",
        Ol(:class => "flex items-center space-x-2",
            Li(:class => "flex items-center",
                A(:href => "../", :class => "text-stone-500 dark:text-stone-400 hover:text-cyan-500 dark:hover:text-cyan-400",
                    "Home"
                ),
                Svg(:class => "w-4 h-4 mx-2 text-stone-400", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M9 5l7 7-7 7")
                )
            ),
            Li(:class => "flex items-center",
                A(:href => "./", :class => "text-stone-500 dark:text-stone-400 hover:text-cyan-500 dark:hover:text-cyan-400",
                    "Manual"
                ),
                chapter_title !== nothing ? Svg(:class => "w-4 h-4 mx-2 text-stone-400", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                    Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                         :d => "M9 5l7 7-7 7")
                ) : nothing
            ),
            chapter_title !== nothing ? Li(:class => "text-stone-800 dark:text-stone-200 font-medium",
                chapter_title
            ) : nothing
        )
    )
end

"""
Previous/Next chapter navigation at the bottom of the page.
"""
function ChapterNav(chapter_id::String)
    prev_chapter, next_chapter = get_chapter_nav(chapter_id)

    Nav(:class => "mt-12 pt-6 border-t border-stone-200 dark:border-stone-700",
        Div(:class => "flex justify-between",
            # Previous
            prev_chapter !== nothing ?
                A(:href => "../$(prev_chapter[1])/",
                  :class => "group flex items-center text-stone-600 dark:text-stone-400 hover:text-cyan-500 dark:hover:text-cyan-400",
                    Svg(:class => "w-5 h-5 mr-2 transition-transform group-hover:-translate-x-1",
                        :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M15 19l-7-7 7-7")
                    ),
                    Div(
                        Span(:class => "text-xs text-stone-400 dark:text-stone-500 block", "Previous"),
                        Span(:class => "font-medium", prev_chapter[2])
                    )
                ) :
                Div(), # Empty spacer

            # Next
            next_chapter !== nothing ?
                A(:href => "../$(next_chapter[1])/",
                  :class => "group flex items-center text-right text-stone-600 dark:text-stone-400 hover:text-cyan-500 dark:hover:text-cyan-400",
                    Div(
                        Span(:class => "text-xs text-stone-400 dark:text-stone-500 block", "Next"),
                        Span(:class => "font-medium", next_chapter[2])
                    ),
                    Svg(:class => "w-5 h-5 ml-2 transition-transform group-hover:translate-x-1",
                        :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M9 5l7 7-7 7")
                    )
                ) :
                Div() # Empty spacer
        )
    )
end

"""
Related chapters "See Also" section.
Shows links to conceptually related chapters (not sequential prev/next).
"""
function RelatedChapters(chapter_id::String)
    related = get_related_chapters(chapter_id)
    if isempty(related)
        return nothing
    end

    Div(:class => "mt-10 p-5 bg-stone-50 dark:bg-stone-800/50 rounded-xl border border-stone-200 dark:border-stone-700",
        Div(:class => "flex items-center gap-2 mb-4",
            # Link icon
            Svg(:class => "w-5 h-5 text-cyan-500 dark:text-cyan-400",
                :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                     :d => "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1")
            ),
            H3(:class => "text-lg font-semibold text-stone-800 dark:text-stone-100",
                "See Also"
            )
        ),
        Div(:class => "grid sm:grid-cols-2 lg:grid-cols-3 gap-3",
            [A(:href => "../$(id)/",
               :class => "group flex items-start gap-3 p-3 rounded-lg bg-white dark:bg-stone-800 border border-stone-200 dark:border-stone-700 hover:border-cyan-300 dark:hover:border-cyan-700 hover:shadow-sm transition-all",
                Div(:class => "flex-shrink-0 w-8 h-8 rounded-lg bg-cyan-100 dark:bg-cyan-900/30 flex items-center justify-center",
                    Svg(:class => "w-4 h-4 text-cyan-600 dark:text-cyan-400",
                        :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z")
                    )
                ),
                Div(
                    Span(:class => "font-medium text-stone-800 dark:text-stone-100 group-hover:text-cyan-600 dark:group-hover:text-cyan-400 transition-colors block",
                        title
                    ),
                    Span(:class => "text-xs text-stone-500 dark:text-stone-400",
                        desc
                    )
                )
            ) for (id, title, desc) in related]...
        )
    )
end

"""
Sidebar component with chapter list.
The sidebar is collapsible on mobile via a toggle button.
"""
function ManualSidebar(current_chapter_id)
    Aside(:id => "manual-sidebar",
          :class => "hidden lg:block w-64 flex-shrink-0",
        Div(:class => "sticky top-4 bg-white dark:bg-stone-800 rounded-xl p-4 shadow-sm border border-stone-200 dark:border-stone-700",
            # Header
            Div(:class => "flex items-center justify-between mb-4 pb-3 border-b border-stone-200 dark:border-stone-700",
                H2(:class => "text-sm font-semibold text-stone-800 dark:text-stone-200 uppercase tracking-wider",
                    "Julia Manual"
                ),
                A(:href => "./", :class => "text-xs text-cyan-500 hover:text-cyan-600 dark:hover:text-cyan-400",
                    "Overview"
                )
            ),
            # Chapter list
            Nav(:class => "space-y-1",
                [SidebarItem(id, title, desc, id == current_chapter_id)
                 for (id, title, desc) in MANUAL_CHAPTERS]...
            )
        )
    )
end

"""
Mobile sidebar toggle button (shown on small screens).
"""
function MobileSidebarToggle()
    Button(:id => "sidebar-toggle",
           :class => "lg:hidden fixed bottom-4 right-4 z-50 bg-cyan-500 hover:bg-cyan-600 text-white p-3 rounded-full shadow-lg transition-colors",
           :aria_label => "Toggle sidebar",
        Svg(:class => "w-6 h-6", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                 :d => "M4 6h16M4 12h16M4 18h16")
        )
    )
end

"""
Mobile sidebar overlay (hidden by default, shown when toggle is clicked).
"""
function MobileSidebarOverlay(current_chapter_id)
    Div(:id => "sidebar-overlay",
        :class => "lg:hidden fixed inset-0 z-40 hidden",
        # Backdrop
        Div(:id => "sidebar-backdrop",
            :class => "absolute inset-0 bg-black/50"),
        # Sidebar panel
        Div(:class => "absolute left-0 top-0 bottom-0 w-72 bg-white dark:bg-stone-800 shadow-xl p-4 overflow-y-auto",
            # Close button
            Div(:class => "flex justify-between items-center mb-4",
                H2(:class => "text-lg font-semibold text-stone-800 dark:text-stone-200",
                    "Julia Manual"
                ),
                Button(:id => "sidebar-close",
                       :class => "p-2 text-stone-500 hover:text-stone-700 dark:hover:text-stone-300",
                       :aria_label => "Close sidebar",
                    Svg(:class => "w-5 h-5", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                             :d => "M6 18L18 6M6 6l12 12")
                    )
                )
            ),
            # Chapter list
            Nav(:class => "space-y-1",
                A(:href => "./", :class => "block px-3 py-2 rounded-lg text-sm text-cyan-600 dark:text-cyan-400 hover:bg-stone-100 dark:hover:bg-stone-700 font-medium mb-2",
                    "Overview"
                ),
                [SidebarItem(id, title, desc, id == current_chapter_id)
                 for (id, title, desc) in MANUAL_CHAPTERS]...
            )
        )
    )
end

"""
JavaScript for mobile sidebar toggle functionality.
"""
function SidebarScript()
    Script(raw"""
        (function() {
            const toggle = document.getElementById('sidebar-toggle');
            const overlay = document.getElementById('sidebar-overlay');
            const backdrop = document.getElementById('sidebar-backdrop');
            const close = document.getElementById('sidebar-close');

            if (toggle && overlay) {
                toggle.addEventListener('click', function() {
                    overlay.classList.remove('hidden');
                    document.body.style.overflow = 'hidden';
                });

                function closeSidebar() {
                    overlay.classList.add('hidden');
                    document.body.style.overflow = '';
                }

                if (backdrop) backdrop.addEventListener('click', closeSidebar);
                if (close) close.addEventListener('click', closeSidebar);
            }
        })();
    """)
end

"""
Manual page layout with sidebar, breadcrumbs, and chapter navigation.

Arguments:
- `children`: The main content of the page
- `chapter_id`: Current chapter identifier (e.g., "variables", "functions")
- `chapter_title`: Display title for the chapter (used in breadcrumbs)

Example:
```julia
ManualLayout(chapter_id="variables", chapter_title="Variables",
    H1("Variables"),
    P("Content here...")
)
```
"""
function ManualLayout(children...; chapter_id::String="", chapter_title::Union{String,Nothing}=nothing)
    Div(:class => "min-h-screen bg-stone-50 dark:bg-stone-900 transition-colors duration-200",
        # Navigation (same as Layout.jl)
        Nav(:class => "bg-white dark:bg-stone-800 border-b border-stone-200 dark:border-stone-700 transition-colors duration-200",
            Div(:class => "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8",
                Div(:class => "flex justify-between h-16",
                    # Logo
                    Div(:class => "flex items-center",
                        A(:href => "../", :class => "flex items-center",
                            Span(:class => "text-2xl font-bold text-cyan-500 dark:text-cyan-400", "WasmTarget"),
                            Span(:class => "text-2xl font-light text-stone-400 dark:text-stone-500", ".jl")
                        )
                    ),
                    # Navigation Links
                    Div(:class => "hidden sm:flex sm:items-center sm:space-x-6",
                        A(:href => "../",
                          :class => "text-stone-600 dark:text-stone-300 hover:text-stone-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                          "Playground"),
                        A(:href => "./",
                          :class => "text-cyan-600 dark:text-cyan-400 px-3 py-2 text-sm font-medium transition-colors",
                          "Manual"),
                        A(:href => "../features/",
                          :class => "text-stone-600 dark:text-stone-300 hover:text-stone-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                          "Features"),
                        A(:href => "../api/",
                          :class => "text-stone-600 dark:text-stone-300 hover:text-stone-900 dark:hover:text-white px-3 py-2 text-sm font-medium transition-colors",
                          "API"),
                        # GitHub link
                        A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl",
                          :class => "text-stone-500 hover:text-stone-700 dark:text-stone-400 dark:hover:text-stone-200 transition-colors",
                          :target => "_blank",
                          :title => "View on GitHub",
                            Svg(:class => "h-5 w-5", :fill => "currentColor", :viewBox => "0 0 24 24",
                                Path(:d => "M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z")
                            )
                        ),
                        # Theme Toggle
                        Div(:class => "ml-2", ThemeToggle())
                    )
                )
            )
        ),

        # Main content area with sidebar
        Div(:class => "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8",
            Div(:class => "flex gap-8",
                # Sidebar (desktop)
                ManualSidebar(chapter_id),

                # Main content
                MainEl(:class => "flex-1 min-w-0",
                    # Breadcrumb
                    Breadcrumb(chapter_title),

                    # Content
                    Article(:class => "prose prose-stone dark:prose-invert prose-cyan max-w-none",
                        children...
                    ),

                    # Related chapters "See Also" section (only if chapter_id is provided)
                    chapter_id != "" ? RelatedChapters(chapter_id) : nothing,

                    # Prev/Next navigation (only if chapter_id is provided)
                    chapter_id != "" ? ChapterNav(chapter_id) : nothing
                )
            )
        ),

        # Mobile sidebar components
        MobileSidebarToggle(),
        MobileSidebarOverlay(chapter_id),
        SidebarScript(),

        # Footer
        Footer(:class => "bg-white dark:bg-stone-800 border-t border-stone-200 dark:border-stone-700 mt-auto transition-colors duration-200",
            Div(:class => "max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8",
                Div(:class => "flex justify-between items-center",
                    P(:class => "text-stone-500 dark:text-stone-400 text-sm",
                        "Built with ",
                        A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :class => "text-cyan-500 dark:text-cyan-400 hover:text-cyan-600 dark:hover:text-cyan-300", :target => "_blank", "Therapy.jl"),
                        " - Powered by ",
                        A(:href => "../", :class => "text-cyan-500 dark:text-cyan-400 hover:text-cyan-600 dark:hover:text-cyan-300", "WasmTarget.jl")
                    ),
                    P(:class => "text-stone-400 dark:text-stone-500 text-sm",
                        "MIT License"
                    )
                )
            )
        )
    )
end
