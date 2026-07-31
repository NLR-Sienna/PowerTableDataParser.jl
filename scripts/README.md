# Development Scripts

This directory contains utility scripts for PSY6 development and validation when working with the OpenAPI schema integration.

## Setup Instructions

### Prerequisites

- Julia 1.10+
- Git
- Access to NLR-Sienna repositories

### 1. Clone PowerOpenAPI Repository

For local development with the OpenAPI schema definitions, create a local clone of the `PowerOpenAPI` repository:

```bash
# Navigate to a development directory
cd ~/path/to/dev

# Clone the PowerOpenAPI repository
git clone https://github.com/NLR-Sienna/PowerOpenAPI.jl.git
```

### 2. Configure Development Environment

Point your Julia environment to the local PowerOpenAPI clone by adding a path dependency in `Project.toml`:

```toml
[deps]
PowerOpenAPI = "your-uuid-here"

[paths]
PowerOpenAPI = "/path/to/PowerOpenAPI.jl"
```

Alternatively, use the Julia REPL:

```julia
using Pkg
Pkg.develop(path="/path/to/PowerOpenAPI.jl")
```

### 3. Instantiate Test Environment

```bash
julia --project=test -e 'using Pkg; Pkg.instantiate()'
```

## Available Scripts

### `build_psy5_reference.jl`

Builds reference data from PSY5 (PowerSystems.jl v5) for comparison and validation.

**Usage:**
```bash
julia scripts/build_psy5_reference.jl
```

**Purpose:** Creates baseline data structures to verify compatibility and correctness of PSY6 implementations.

### `compare_structure.jl`

Validates structural consistency between PSY5 and PSY6 implementations.

**Usage:**
```bash
julia scripts/compare_structure.jl
```

**Purpose:** Ensures type hierarchies and data structures match between versions, catching breaking changes early.

### `compare_values.jl`

Compares actual data values between PSY5 and PSY6 outputs.

**Usage:**
```bash
julia scripts/compare_values.jl
```

**Purpose:** Verifies numerical correctness and data fidelity during migration to new schema.

### `fix_rts_data.jl`

Utilities for correcting and validating RTS (Reliability Test System) test data.

**Usage:**
```bash
julia scripts/fix_rts_data.jl
```

**Purpose:** Ensures test data integrity when migrating to new schema formats.

## Workflow Example

1. **Set up local PowerOpenAPI:**
   ```bash
   git clone https://github.com/NLR-Sienna/PowerOpenAPI.jl.git ../PowerOpenAPI.jl
   ```

2. **Configure path dependency:**
   ```julia
   using Pkg
   Pkg.develop(path="../PowerOpenAPI.jl")
   ```

3. **Build reference data from PSY5:**
   ```bash
   julia scripts/build_psy5_reference.jl
   ```

4. **Validate structure migration:**
   ```bash
   julia scripts/compare_structure.jl
   ```

5. **Verify data values:**
   ```bash
   julia scripts/compare_values.jl
   ```

6. **Run full test suite:**
   ```bash
   julia --project=test test/runtests.jl
   ```

## Notes

- These scripts are development aids and are not part of the package distribution
- Some scripts may require additional dependencies installed in the `test/` environment
- Reference data is cached in `psy5_reference/` to avoid repeated builds
