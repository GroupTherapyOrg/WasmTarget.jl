module JumpNotebookMaterialization

export materialize_notebook

const CELL_ORDER_MARKER = "# ╔═╡ Cell order:\n"
const PROJECT_CELL = "00000000-0000-0000-0000-000000000001"
const MANIFEST_CELL = "00000000-0000-0000-0000-000000000002"
const SOURCE_CELLS = (
    "00000000-0000-4000-8000-000000000101",
    "00000000-0000-4000-8000-000000000102",
)

function canonical_lf(text::AbstractString, label::AbstractString)
    normalized = replace(text, "\r\n" => "\n")
    occursin('\r', normalized) &&
        error("$label contains a lone carriage return")
    return normalized
end

"""
Copy a committed certification notebook into an isolated fixture tree and
inject the exact pinned Pluto environment used for browser certification.

The committed notebook remains readable and reviewable without duplicating a
large machine-generated manifest. The materialized notebook is the executable
artifact retained by the promotion gate.
"""
function materialize_notebook(
    source::AbstractString,
    destination::AbstractString,
    environment::AbstractString,
    canonical_sources::AbstractVector{<:AbstractString},
)
    text = canonical_lf(read(source, String), source)
    count(CELL_ORDER_MARKER, text) == 1 ||
        error("notebook must contain exactly one Cell order marker")
    body, order = split(text, CELL_ORDER_MARKER; limit=2)
    project_path = joinpath(environment, "Project.toml")
    manifest_path = joinpath(environment, "Manifest.toml")
    project = canonical_lf(read(project_path, String), project_path)
    manifest = canonical_lf(read(manifest_path, String), manifest_path)
    occursin("\"\"\"", project) &&
        error("Project.toml cannot be embedded in a Pluto triple-quoted cell")
    occursin("\"\"\"", manifest) &&
        error("Manifest.toml cannot be embedded in a Pluto triple-quoted cell")
    length(canonical_sources) <= length(SOURCE_CELLS) ||
        error("too many canonical source cells")
    source_cells = join(
        (
            "# ╔═╡ $(SOURCE_CELLS[i])\n" *
            canonical_lf(read(path, String), path) *
            "\n\n"
            for (i, path) in enumerate(canonical_sources)
        ),
    )
    source_order = join(
        ("# ╠═$(SOURCE_CELLS[i])\n" for i in eachindex(canonical_sources)),
    )
    materialized =
        body *
        source_cells *
        "# ╔═╡ $PROJECT_CELL\n" *
        "PLUTO_PROJECT_TOML_CONTENTS = \"\"\"\n" *
        project *
        "\"\"\"\n\n" *
        "# ╔═╡ $MANIFEST_CELL\n" *
        "PLUTO_MANIFEST_TOML_CONTENTS = \"\"\"\n" *
        manifest *
        "\"\"\"\n\n" *
        CELL_ORDER_MARKER *
        source_order *
        order *
        "# ╟─$PROJECT_CELL\n" *
        "# ╟─$MANIFEST_CELL\n"
    mkpath(dirname(destination))
    write(destination, materialized)
    return destination
end

end
