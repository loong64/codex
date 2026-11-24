#!/usr/bin/env python3
"""Cross-compile the pinned GNU Linux voice runtime on a Linux build host."""

import argparse
import os
from pathlib import Path
import platform
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_native import NativeBuild

# Rust's RISC-V triple includes the ISA extensions; upstream build systems use
# the CPU family instead. Both targets use the little-endian, double-float ABI.
TARGETS = {
    "loongarch64-unknown-linux-gnu": "loongarch64",
    "riscv64gc-unknown-linux-gnu": "riscv64",
}


class CrossBuild(NativeBuild):
    def validate_target(self, args):
        if platform.system() != "Linux" or args.target not in TARGETS:
            raise ValueError(
                "Cross voice builds require Linux and a supported GNU target"
            )

    def __init__(self, args, inherited_environment):
        super().__init__(args, inherited_environment)
        self.cpu = TARGETS[args.target]
        self.build_compilers = {
            name: getattr(args, "build_" + name).absolute() for name in ("cc", "cxx")
        }
        for tool in self.build_compilers.values():
            if not tool.is_file():
                raise ValueError(f"Missing build tool: {tool}")
        # Building Ninja must never receive target flags, archivers, or libraries.
        self.build_environment = {
            key: value
            for key, value in self.environment.items()
            if key
            not in (
                "CC",
                "CXX",
                "AR",
                "RANLIB",
                "CFLAGS",
                "CXXFLAGS",
                "LDFLAGS",
                "PKG_CONFIG_LIBDIR",
                "CMAKE_PREFIX_PATH",
            )
        }
        self.build_environment.update(
            {name.upper(): str(path) for name, path in self.build_compilers.items()}
        )
        self.build_environment["PATH"] = os.pathsep.join(
            [
                *(str(path.parent) for path in self.build_compilers.values()),
                self.build_environment["PATH"],
            ]
        )
        self.record["build_compilers"] = {
            name: str(path) for name, path in self.build_compilers.items()
        }
        self.cmake_platform += [
            # Zig 0.14 does not support the linker's --dependency-file option.
            "-DCMAKE_LINK_DEPENDS_USE_LINKER=FALSE",
            "-DCMAKE_SYSTEM_NAME=Linux",
            f"-DCMAKE_SYSTEM_PROCESSOR={self.cpu}",
            f"-DCMAKE_FIND_ROOT_PATH={self.prefix}",
            "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER",
            "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY",
            "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
            "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY",
        ]

    def libffi_configure_options(self):
        return [
            f"--build={platform.machine().lower()}-unknown-linux-gnu",
            f"--host={self.cpu}-unknown-linux-gnu",
        ]

    def cmake(self, name, options, *, bootstrap=False):
        if not bootstrap:
            return super().cmake(name, options)
        target_tools, target_environment, target_platform = (
            self.toolchain,
            self.environment,
            self.cmake_platform,
        )
        try:
            self.toolchain = {
                key: value
                for key, value in target_tools.items()
                if key not in ("ar", "ranlib")
            } | self.build_compilers
            self.environment = self.build_environment
            self.cmake_platform = []
            return super().cmake(name, options, bootstrap=True)
        finally:
            self.toolchain, self.environment, self.cmake_platform = (
                target_tools,
                target_environment,
                target_platform,
            )

    def meson(self, name, options):
        cross_file = self.output / "meson-cross.ini"
        native_file = self.output / "meson-native.ini"
        # repr() preserves quotes, spaces and literal $ORIGIN in Meson strings.
        binaries = {
            "c": str(self.toolchain["cc"]),
            "cpp": str(self.toolchain["cxx"]),
            "ar": str(self.toolchain["ar"]),
            "pkg-config": str(self.toolchain["pkg_config"]),
        }
        include = f"-I{self.prefix / 'include'}"
        link = [f"-L{self.prefix / 'lib'}", "-Wl,-rpath,$ORIGIN:$ORIGIN/.."]
        cross_file.write_text(
            "[binaries]\n"
            + "".join(f"{key} = {value!r}\n" for key, value in binaries.items())
            + "\n[host_machine]\n"
            + f"system = 'linux'\ncpu_family = '{self.cpu}'\ncpu = '{self.cpu}'\n"
            + "endian = 'little'\n"
            + "\n[properties]\nneeds_exe_wrapper = true\n"
            # Known GNU Linux probe results; do not execute target binaries.
            + "have_c99_vsnprintf = true\nhave_c99_snprintf = true\n"
            + "have_unix98_printf = true\nhave_proc_self_cmdline = true\n"
            + f"pkg_config_libdir = {[str(self.prefix / p) for p in ('lib/pkgconfig', 'share/pkgconfig')]!r}\n"
            + "\n[built-in options]\n"
            + f"c_args = {[*self.flags['CFLAGS'], include]!r}\n"
            + f"cpp_args = {[*self.flags['CXXFLAGS'], include]!r}\n"
            + f"c_link_args = {[*self.flags['LDFLAGS'], *link]!r}\n"
            + f"cpp_link_args = {[*self.flags['LDFLAGS'], *link]!r}\n",
            encoding="utf-8",
        )
        native_file.write_text(
            "[binaries]\n"
            + f"c = {str(self.build_compilers['cc'])!r}\n"
            + f"cpp = {str(self.build_compilers['cxx'])!r}\n"
            + "\n[built-in options]\n"
            + "c_args = []\ncpp_args = []\nc_link_args = []\ncpp_link_args = []\n",
            encoding="utf-8",
        )
        return super().meson(
            name, ["--cross-file", cross_file, "--native-file", native_file, *options]
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "archives",
        "output",
        "cc",
        "cxx",
        "ar",
        "ranlib",
        "build-cc",
        "build-cxx",
        "cmake",
        "make",
        "pkg-config",
        "shell",
    ):
        parser.add_argument(f"--{name}", type=Path, required=True)
    for name in ("c-flag", "cxx-flag", "link-flag"):
        parser.add_argument(f"--{name}", action="append", default=[])
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if sys.version_info < (3, 12) or args.jobs < 1:
        parser.error("Python 3.12+ and a positive --jobs value are required")
    args.deployment_target = None
    args.bootstrap_make = None
    CrossBuild(args, os.environ).build()


if __name__ == "__main__":
    main()
