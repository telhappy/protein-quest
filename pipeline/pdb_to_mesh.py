#!/usr/bin/env python3
"""
PDB -> Godot-importable glTF mesh pipeline.

Downloads a PDB structure, extracts one protein chain (dropping any bound
ligand/ion/water), builds an approximate solvent-excluded surface (SES) by
voxelizing van der Waals spheres and applying a probe-radius morphological
closing, extracts the isosurface with marching cubes, and exports it as a
glTF/.glb mesh. The centroid of a chosen ligand (e.g. ATP) is written out
separately as a "binding site" goal point, in the same coordinate frame as
the mesh so it can be placed directly as a goal-area marker in Godot.

Example:
    python pdb_to_mesh.py --pdb-id 1ATP --chain E
"""

import argparse
import json
from pathlib import Path

import numpy as np
import requests
import trimesh
from Bio.PDB import PDBParser
from scipy.ndimage import distance_transform_edt
from scipy.spatial import cKDTree
from skimage.measure import marching_cubes

# Bondi van der Waals radii (Angstrom); extend as needed for other elements.
VDW_RADII = {
    "H": 1.20, "C": 1.70, "N": 1.55, "O": 1.52, "S": 1.80,
    "P": 1.80, "F": 1.47, "CL": 1.75, "BR": 1.85, "I": 1.98,
    "MN": 1.73, "MG": 1.73, "ZN": 1.39, "CA": 2.31, "NA": 2.27,
    "K": 2.75, "FE": 1.94,
}
DEFAULT_VDW_RADIUS = 1.70

# Classic amino-acid property coloring (RGB 0-1). Phosphorylated residues get
# their own color since they're often functionally significant (e.g. Thr197
# in PKA's own activation loop, which is what makes 1ATP catalytically
# active in the first place).
RESIDUE_COLORS = {
    # hydrophobic / nonpolar -- tan
    "ALA": (0.85, 0.75, 0.45), "VAL": (0.85, 0.75, 0.45), "LEU": (0.85, 0.75, 0.45),
    "ILE": (0.85, 0.75, 0.45), "PRO": (0.85, 0.75, 0.45), "PHE": (0.85, 0.75, 0.45),
    "MET": (0.85, 0.75, 0.45), "TRP": (0.85, 0.75, 0.45), "GLY": (0.85, 0.75, 0.45),
    # polar / uncharged -- green
    "SER": (0.45, 0.75, 0.55), "THR": (0.45, 0.75, 0.55), "CYS": (0.45, 0.75, 0.55),
    "TYR": (0.45, 0.75, 0.55), "ASN": (0.45, 0.75, 0.55), "GLN": (0.45, 0.75, 0.55),
    # acidic (negative) -- red
    "ASP": (0.85, 0.25, 0.25), "GLU": (0.85, 0.25, 0.25),
    # basic (positive) -- blue
    "LYS": (0.30, 0.45, 0.90), "ARG": (0.30, 0.45, 0.90), "HIS": (0.30, 0.45, 0.90),
    # phosphorylated -- magenta
    "SEP": (0.95, 0.35, 0.85), "TPO": (0.95, 0.35, 0.85), "PTR": (0.95, 0.35, 0.85),
}
DEFAULT_RESIDUE_COLOR = (0.7, 0.7, 0.7)

RCSB_URL = "https://files.rcsb.org/download/{pdb_id}.pdb"


def download_pdb(pdb_id: str, out_path: Path) -> Path:
    if out_path.exists():
        print(f"[download] {out_path} already exists, skipping download")
        return out_path
    url = RCSB_URL.format(pdb_id=pdb_id.upper())
    print(f"[download] fetching {url}")
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(resp.content)
    print(f"[download] saved to {out_path} ({len(resp.content)} bytes)")
    return out_path


def element_of(atom) -> str:
    elem = (atom.element or "").strip().upper()
    if elem:
        return elem
    name = atom.get_name().strip()
    letters = "".join(c for c in name if c.isalpha())
    return letters[:1].upper() or "C"


def vdw_radius(element: str) -> float:
    return VDW_RADII.get(element.upper(), DEFAULT_VDW_RADIUS)


def residue_color(resname: str) -> tuple:
    return RESIDUE_COLORS.get(resname.strip().upper(), DEFAULT_RESIDUE_COLOR)


def extract_chain_atoms(structure, chain_id: str, exclude_resnames):
    """Protein atoms of a chain: everything except the given HETATM resnames
    (ligands/ions/water). Modified residues recorded as HETATM (e.g. SEP,
    TPO phosphoserine/threonine) are kept, since they are still part of the
    polypeptide backbone, not separate bound molecules."""
    atoms = []
    model = next(iter(structure))
    for chain in model:
        if chain.id != chain_id:
            continue
        for residue in chain:
            if residue.get_resname().strip() in exclude_resnames:
                continue
            for atom in residue:
                if element_of(atom) == "H":
                    continue
                atoms.append(atom)
    return atoms


def extract_ligand_atoms(structure, resname: str):
    """All atoms of a given HETATM residue name, anywhere in the structure."""
    atoms = []
    model = next(iter(structure))
    for chain in model:
        for residue in chain:
            if residue.get_resname().strip() == resname:
                atoms.extend(list(residue))
    return atoms


def centroid(atoms) -> np.ndarray:
    coords = np.array([a.get_coord() for a in atoms], dtype=np.float64)
    return coords.mean(axis=0)


def build_vdw_mask(coords: np.ndarray, radii: np.ndarray, origin: np.ndarray,
                    spacing: float, dims: np.ndarray) -> np.ndarray:
    """Rasterize the union of atomic VdW spheres onto a boolean grid."""
    mask = np.zeros(dims, dtype=bool)
    gx = origin[0] + spacing * np.arange(dims[0])
    gy = origin[1] + spacing * np.arange(dims[1])
    gz = origin[2] + spacing * np.arange(dims[2])

    for center, radius in zip(coords, radii):
        lo = np.floor((center - radius - origin) / spacing).astype(int)
        hi = np.ceil((center + radius - origin) / spacing).astype(int)
        lo = np.clip(lo, 0, dims - 1)
        hi = np.clip(hi, 0, dims - 1)
        if np.any(hi < lo):
            continue
        xs = gx[lo[0]:hi[0] + 1]
        ys = gy[lo[1]:hi[1] + 1]
        zs = gz[lo[2]:hi[2] + 1]
        dx = (xs[:, None, None] - center[0]) ** 2
        dy = (ys[None, :, None] - center[1]) ** 2
        dz = (zs[None, None, :] - center[2]) ** 2
        local = (dx + dy + dz) <= radius ** 2
        mask[lo[0]:hi[0] + 1, lo[1]:hi[1] + 1, lo[2]:hi[2] + 1] |= local
    return mask


def dilate(mask: np.ndarray, radius: float, spacing: float) -> np.ndarray:
    if radius <= 0:
        return mask
    dist = distance_transform_edt(~mask, sampling=spacing)
    return mask | (dist <= radius)


def erode(mask: np.ndarray, radius: float, spacing: float) -> np.ndarray:
    if radius <= 0:
        return mask
    return ~dilate(~mask, radius, spacing)


def solvent_excluded_surface_mask(coords, radii, spacing: float, probe_radius: float,
                                   padding: float = 2.0):
    """Approximate the solvent-excluded surface (SES) as a morphological
    closing (dilate then erode) of the van der Waals union by the probe
    radius. This mirrors the construction used by grid-based SES tools such
    as EDTSurf: the closing fills in crevices the probe sphere cannot reach,
    turning the raw VdW surface into a probe-rolled ("reentrant") surface.
    """
    margin = padding + probe_radius + radii.max()
    mins = coords.min(axis=0) - margin
    maxs = coords.max(axis=0) + margin
    dims = np.ceil((maxs - mins) / spacing).astype(int) + 1

    print(f"[surface] grid dims={tuple(int(d) for d in dims)} spacing={spacing}A "
          f"({int(dims.prod()):,} voxels)")

    vdw_mask = build_vdw_mask(coords, radii, mins, spacing, dims)
    dilated = dilate(vdw_mask, probe_radius, spacing)
    ses_mask = erode(dilated, probe_radius, spacing)
    return ses_mask, mins


def mesh_from_mask(mask: np.ndarray, origin: np.ndarray, spacing: float,
                    smooth_iterations: int = 8) -> trimesh.Trimesh:
    verts, faces, normals, _ = marching_cubes(
        mask.astype(np.float32), level=0.5, spacing=(spacing, spacing, spacing)
    )
    verts = verts + origin
    mesh = trimesh.Trimesh(vertices=verts, faces=faces, vertex_normals=normals,
                            process=True)
    mesh.remove_unreferenced_vertices()
    if smooth_iterations > 0:
        trimesh.smoothing.filter_laplacian(mesh, iterations=smooth_iterations)
    mesh.fix_normals()
    return mesh


def assign_vertex_colors(mesh: trimesh.Trimesh, atom_coords: np.ndarray,
                          atom_colors: np.ndarray) -> None:
    # NOTE: must run *after* decimation -- simplify_quadric_decimation()
    # returns a fresh Trimesh that drops any .visual set beforehand (and
    # the glTF exporter then silently omits normals too), which is what
    # made earlier exports render as a flat white mesh in Godot. Colors are
    # looked up per final vertex (nearest source atom) rather than carried
    # through decimation, since decimation also relocates/merges vertices.
    tree = cKDTree(atom_coords)
    _, nearest = tree.query(mesh.vertices)
    rgba = np.full((len(mesh.vertices), 4), 255, dtype=np.uint8)
    rgba[:, :3] = (atom_colors[nearest] * 255).astype(np.uint8)
    mesh.visual = trimesh.visual.color.ColorVisuals(mesh, vertex_colors=rgba)


def gltf_material_postprocessor(roughness: float = 0.75):
    # trimesh's ColorVisuals (needed for per-vertex COLOR_0 export) has no
    # slot for a PBR material, so the material is injected directly into the
    # glTF JSON tree at export time instead. baseColorFactor stays white so
    # it doesn't tint the vertex colors (glTF multiplies COLOR_0 into it).
    def add_material(tree: dict) -> dict:
        tree["materials"] = [{
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": roughness,
            },
            "doubleSided": True,
        }]
        for mesh_entry in tree.get("meshes", []):
            for prim in mesh_entry.get("primitives", []):
                prim["material"] = 0
        return tree
    return add_material


def maybe_decimate(mesh: trimesh.Trimesh, target_faces: int) -> trimesh.Trimesh:
    if target_faces <= 0 or len(mesh.faces) <= target_faces:
        return mesh
    try:
        simplified = mesh.simplify_quadric_decimation(face_count=target_faces)
        print(f"[mesh] decimated {len(mesh.faces):,} -> {len(simplified.faces):,} faces")
        return simplified
    except Exception as exc:
        print(f"[mesh] decimation skipped ({exc}); "
              f"install `fast-simplification` to enable it")
        return mesh


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pdb-id", default="1ATP")
    parser.add_argument("--chain", default="E", help="Chain to extract (catalytic subunit)")
    parser.add_argument("--exclude-resnames", nargs="*", default=["HOH", "ATP", "MN"],
                         help="HETATM residues to drop from the protein mesh")
    parser.add_argument("--ligand-resname", default="ATP",
                         help="Ligand whose centroid becomes the binding-site goal point")
    parser.add_argument("--extra-site-resnames", nargs="*", default=["MN"],
                         help="Additional removed hetero groups to also record in the JSON")
    parser.add_argument("--grid-spacing", type=float, default=0.5, help="Voxel size in Angstrom")
    parser.add_argument("--probe-radius", type=float, default=1.4,
                         help="Solvent probe radius in Angstrom (1.4 = water)")
    parser.add_argument("--smooth-iterations", type=int, default=8)
    parser.add_argument("--target-faces", type=int, default=150_000,
                         help="Decimate to at most this many faces (0 = disable)")
    parser.add_argument("--work-dir", default="work", help="Where to cache the downloaded PDB")
    parser.add_argument("--out-dir", default="../assets/1ATP", help="Output directory")
    args = parser.parse_args()

    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    pdb_path = download_pdb(args.pdb_id, work_dir / f"{args.pdb_id.upper()}.pdb")

    parser_bio = PDBParser(QUIET=True)
    structure = parser_bio.get_structure(args.pdb_id, pdb_path)

    protein_atoms = extract_chain_atoms(structure, args.chain, set(args.exclude_resnames))
    if not protein_atoms:
        raise SystemExit(f"No protein atoms found for chain '{args.chain}'")
    print(f"[extract] chain {args.chain}: {len(protein_atoms)} protein atoms "
          f"(dropped {args.exclude_resnames})")

    coords = np.array([a.get_coord() for a in protein_atoms], dtype=np.float64)
    radii = np.array([vdw_radius(element_of(a)) for a in protein_atoms])
    atom_colors = np.array(
        [residue_color(a.get_parent().get_resname()) for a in protein_atoms]
    )

    ses_mask, origin = solvent_excluded_surface_mask(
        coords, radii, args.grid_spacing, args.probe_radius
    )
    mesh = mesh_from_mask(ses_mask, origin, args.grid_spacing, args.smooth_iterations)
    mesh = maybe_decimate(mesh, args.target_faces)
    assign_vertex_colors(mesh, coords, atom_colors)
    print(f"[mesh] final: {len(mesh.vertices):,} vertices, {len(mesh.faces):,} faces, "
          f"watertight={mesh.is_watertight}")

    glb_path = out_dir / f"{args.pdb_id.upper()}_chain{args.chain}_surface.glb"
    mesh.export(glb_path, include_normals=True,
                tree_postprocessor=gltf_material_postprocessor())
    print(f"[export] wrote {glb_path}")

    # --- Binding-site / goal-area JSON -------------------------------------
    binding_site = {}
    removed_ligands = {}
    for resname in [args.ligand_resname, *args.extra_site_resnames]:
        atoms = extract_ligand_atoms(structure, resname)
        if not atoms:
            print(f"[ligand] no atoms found for resname '{resname}', skipping")
            continue
        c = centroid(atoms)
        removed_ligands[resname] = {
            "centroid": c.tolist(),
            "atom_count": len(atoms),
            "atom_positions": [a.get_coord().tolist() for a in atoms],
        }
        if resname == args.ligand_resname:
            binding_site = {
                "label": resname,
                "centroid": c.tolist(),
                "atom_count": len(atoms),
            }

    payload = {
        "pdb_id": args.pdb_id.upper(),
        "source_chain": args.chain,
        "coordinate_units": "angstrom",
        "coordinate_frame": "Raw PDB Cartesian coordinates; identical to the "
                             "exported mesh's vertex coordinates (no recentering "
                             "applied). Note glTF/Godot are Y-up, right-handed, "
                             "while PDB coordinate axes are arbitrary -- reorient "
                             "the imported scene node in Godot if a specific "
                             "up-axis is required.",
        "grid_spacing_angstrom": args.grid_spacing,
        "probe_radius_angstrom": args.probe_radius,
        "binding_site": binding_site,
        "removed_ligands": removed_ligands,
    }
    json_path = out_dir / f"{args.pdb_id.upper()}_binding_site.json"
    json_path.write_text(json.dumps(payload, indent=2))
    print(f"[export] wrote {json_path}")


if __name__ == "__main__":
    main()
