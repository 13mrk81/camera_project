# Camera FPGA Projects

This repository contains the Gowin camera/HyperRAM implementation and related RTL projects, protocol experiments, and supporting source files.

## Repository layout

```text
camera_project/
├── gowin_cameradrive/                 # Main Gowin FPGA project
│   ├── src/                            # Project RTL, generated IP and constraints
│   └── impl/                           # Gowin implementation outputs and reports
│
├── projects/                           # Standalone RTL projects / experiments
│   ├── Camera_HyperRAM_OneFrame_Integrated/
│   │   └── hyperram_line_rtl/           # Integrated camera-to-HyperRAM RTL
│   └── uart_based_protocol/             # UART framed-protocol project
│
├── supporting_rtl/                     # Standalone/reference RTL files
│   ├── Camera_HyperRAM_OneFrame.vhd
│   ├── camera_interface_one_frame.vhd
│   └── i2c_master.vhd
│
├── docs/                               # Project notes and reminders
├── archives/                           # Packaged snapshots / ZIP archives
└── README.md
```

## Main Gowin project

The main hardware project is in `gowin_cameradrive/`. Open the Gowin project file:

`gowin_cameradrive/HYPER_RAM_CONTROL.gprj`

The project targets the Gowin device configured in that project file. Its source tree includes the camera capture path, RGB565 packing, asynchronous FIFO, HyperRAM interface IP, line readout logic, clock-generation IP, and timing/pin constraint files.

Generated synthesis and place-and-route outputs are retained under `gowin_cameradrive/impl/` as part of the current project snapshot. They are implementation artifacts and may need regeneration after source, device, constraint, or Gowin EDA version changes.

## Active camera stream protocol

The main gowin_cameradrive camera top uses a one-way UART stream: Tang Nano 4K KEY1 triggers capture, FPGA TX reports stages and sends CRC-protected Gray8 rows derived from the RGB565 frame in HyperRAM, and MATLAB is receive-only. See DESIGN_NOTES.md, UART_ONE_WAY_PROTOCOL.md, IMPLEMENTATION_STATUS.md, and VALIDATION.md for the protocol, CDC/buffer assumptions, recovery instructions, and remaining hardware sign-off checks.

## Projects

### Camera_HyperRAM_OneFrame_Integrated

Located at `projects/Camera_HyperRAM_OneFrame_Integrated/hyperram_line_rtl/`.

This project integrates a GC0308-style camera capture path with RGB565 frame packing, HyperRAM frame storage, line-by-line readback, raw RGB565 serialization, and a UART byte-stream interface.

The directory README describes the module roles, data layout, clock domains, handshakes, and verification checklist. Read that document before integrating or modifying the RTL.

Important integration points to verify on the target design include:
- HyperRAM generated-IP command and read-response timing.
- Burst length and address-step assumptions.
- Camera/I2C component binding and port compatibility.
- FIFO clock-domain crossings and occupancy.
- UART ready/valid behavior and final-byte idle indication.

The presence of RTL files does not by itself imply that the complete design has been synthesized, timing-closed, or validated on hardware.

### uart_based_protocol

Located at `projects/uart_based_protocol/`.

This is a separate UART framed-protocol implementation and test project. It contains the VHDL protocol logic, UART RX/TX modules, a Gowin test top and constraints, and a MATLAB receiver/analysis script. Its Gowin implementation outputs are retained in `impl/`.

## Supporting RTL

`supporting_rtl/` contains standalone source files that were previously stored at the repository root. Some may overlap with or be earlier/later copies of modules in `gowin_cameradrive/src/` or the integrated camera project.

**Do not add every file in this directory to a Gowin project automatically.** Check entity names, port lists, generics, clock assumptions, and source revision first. In particular, avoid compiling duplicate entities with the same design-unit names into one project.

## Documentation and archives

- `docs/`: existing project notes and reminders.
- `archives/`: ZIP snapshot of the integrated camera project. The extracted project directory is the preferred location for browsing and editing source.

## Working with the repository

1. Clone the repository and open `gowin_cameradrive/HYPER_RAM_CONTROL.gprj` in Gowin EDA.
2. Keep project-specific generated IP and constraints with the project that uses them.
3. Treat the directories under `projects/` as independent projects unless their local documentation says otherwise.
4. Before reusing RTL from `supporting_rtl/`, compare it with the active project version and check for duplicate entity/module declarations.
5. After changing RTL or constraints, rerun synthesis, place-and-route, timing analysis, and board-level verification as appropriate.

## Notes

- The folder name `projects/` is intentional: these are ordinary directories in this repository, **not Git submodules**.
- The repository is organized for clarity; file relocation does not establish that all projects share compatible clocks, interfaces, constraints, or target devices.
