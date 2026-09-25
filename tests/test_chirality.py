"""Run with the rrm-recon Python environment on a compute node."""
import ast
from pathlib import Path

import numpy as np
from pymatgen.core import Molecule
from pymatgen.symmetry.analyzer import PointGroupAnalyzer


def main():
    source = Path(__file__).resolve().parents[1] / "rrm_reconstruction_v18.py"
    # Load the helper without executing the script's command-line file reads.
    tree = ast.parse(source.read_text())
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "wchiral")
    namespace = {"np": np}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
    cases = [
        ("HCN", ["H", "C", "N"], [[0, 0, -1], [0, 0, 0], [0, 0, 1.2]], "C*v", False),
        ("CCO", ["C", "C", "O"], [[-1.3, 0, 0], [0, 0, 0], [1.2, 0, 0]], "C*v", False),
        ("OCO", ["O", "C", "O"], [[0, -1.2, 0], [0, 0, 0], [0, 1.2, 0]], "D*h", False),
        ("water", ["O", "H", "H"], [[0, 0, 0], [1, 0, 0], [0, 1, 0]], "C2v", False),
        ("CHFClBr", ["C", "H", "F", "Cl", "Br"],
         [[0, 0, 0], [1, 1, 1], [-1, -1, 1], [-1, 1, -1], [1, -1, -1]], "C1", True),
    ]
    for name, species, coordinates, point_group, expected in cases:
        # Check the original and its inversion, including a truly chiral control.
        for sign in (1, -1):
            molecule = Molecule(species, sign * np.array(coordinates)).get_centered_molecule()
            analyzer = PointGroupAnalyzer(molecule, tolerance=0.1)
            assert analyzer.sch_symbol == point_group, (name, analyzer.sch_symbol)
            actual = namespace["wchiral"](analyzer.get_symmetry_operations(), analyzer.sch_symbol)
            assert actual is expected, (name, sign, actual)
    print("PASS: linear molecules with/without repeated elements, bent achiral and chiral controls")


if __name__ == "__main__":
    main()
