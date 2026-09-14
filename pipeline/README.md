# PDB -> Godot mesh pipeline

Converts a PDB structure into a glTF surface mesh plus a binding-site JSON,
ready to import into Godot (`res://assets/<PDB_ID>/`).

## What it does

1. Downloads `<PDB_ID>.pdb` from RCSB (cached under `pipeline/work/`).
2. Extracts one chain's protein atoms via Biopython, dropping the given
   HETATM residues (ligand/ions/water). Modified residues stored as HETATM
   (e.g. phosphoserine `SEP`, phosphothreonine `TPO`) are kept since they're
   still part of the backbone.
3. Rasterizes each atom as a van der Waals sphere onto a voxel grid, then
   approximates the solvent-excluded surface (SES) with a probe-radius
   morphological closing (dilate by the probe radius, then erode back) —
   the same construction used by grid-based SES tools like EDTSurf.
4. Extracts the isosurface with marching cubes (`scikit-image`), lightly
   Laplacian-smooths it, and optionally decimates to a face budget.
5. Colors each final vertex by its nearest atom's amino-acid property
   (hydrophobic/polar/acidic/basic/phosphorylated — classic 5-category
   scheme) as a per-vertex `COLOR_0` attribute, and exports the mesh as
   binary glTF (`.glb`) via `trimesh`, injecting a PBR material (white
   base color, double-sided) directly into the glTF JSON so the vertex
   colors show up unmodified while lighting still shades the surface.
6. Computes the centroid of the removed ligand (default: `ATP`) in the same
   coordinate frame as the mesh, and writes it to a JSON file as a
   "binding site" goal point (also includes any other removed hetero groups,
   e.g. `MN`, for reference).

## Setup

```bash
cd pipeline
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`fast-simplification` enables mesh decimation (`--target-faces`); without it
the pipeline still runs, just skips decimation.

## Run

```bash
python pdb_to_mesh.py --pdb-id 1ATP --chain E --out-dir ../assets/1ATP
```

Outputs:
- `../assets/1ATP/1ATP_chainE_surface.glb` — the molecular surface mesh
  (import directly in Godot; it's `res://assets/1ATP/...` from the project
  root).
- `../assets/1ATP/1ATP_binding_site.json` — `binding_site.centroid` is the
  ATP center of mass in the mesh's own coordinate frame (raw PDB Angstrom
  coordinates, no recentering), so you can place a goal-area `Area3D` at
  that position directly.

## Notable options

| Flag | Default | Meaning |
|---|---|---|
| `--grid-spacing` | `0.5` | Voxel size (A). Smaller = more detail, slower, more triangles. |
| `--probe-radius` | `1.4` | Solvent probe radius (A); 1.4 approximates water. |
| `--target-faces` | `150000` | Decimation budget (`0` disables). |
| `--exclude-resnames` | `HOH ATP MN` | HETATM residues dropped from the protein mesh. |
| `--ligand-resname` | `ATP` | Which removed ligand becomes the binding-site goal point. |
| `--extra-site-resnames` | `MN` | Other removed groups also recorded (not used as the goal). |

## Caveats (minimal-viable implementation)

- The SES approximation is a voxel-grid morphological closing, not an exact
  analytical SES (à la MSMS) — good enough for a game-ready surface, but
  fine crevices smaller than the probe radius / grid spacing are lost.
- Coordinate axes are left as-is from the PDB file. PDB structures have no
  fixed "up" convention, while glTF/Godot are Y-up; reorient the imported
  scene node in Godot if a specific orientation matters for gameplay.
- Only the first model in the PDB file is used (relevant for NMR ensembles;
  1ATP is a single X-ray structure so this doesn't apply here).
- Godot's glTF importer does not automatically use `COLOR_0` as albedo, even
  though the exported material is `doubleSided`/vertex-colored per spec; the
  Godot side (`scripts/main.gd`) explicitly enables
  `vertex_color_use_as_albedo` on the imported material at runtime.
