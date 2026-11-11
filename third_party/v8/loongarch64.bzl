"""LoongArch GNU and musl release artifacts built from the shared upstream V8 graph."""

load("@rules_cc//cc:cc_static_library.bzl", "cc_static_library")

def loongarch64_release_pairs():
    """Declare the archive and bindings used by both release variants."""
    for libc in ["gnu", "musl"]:
        cc_static_library(
            name = "v8_152_2_0_loongarch64_unknown_linux_{}_base".format(libc),
            features = ["-symbol_check", "-validate-static-library"],
            deps = [
                ":rusty_v8_custom_libcxx_runtime",
                ":v8_152_2_0_binding",
                ":loongarch64_abi",
            ],
        )
        native.genrule(
            name = "v8_152_2_0_loongarch64_unknown_linux_{}_release".format(libc),
            srcs = [
                ":v8_152_2_0_loongarch64_unknown_linux_{}_base".format(libc),
                "@llvm//runtimes/compiler-rt:clang_rt.builtins.static",
            ],
            outs = ["libv8_152_2_0_loongarch64_unknown_linux_{}.a".format(libc)],
            cmd = """
              cat > "$(@D)/loongarch64-{libc}-merge.mri" <<'EOF'
create $@
addlib $(location :v8_152_2_0_loongarch64_unknown_linux_{libc}_base)
addlib $(location @llvm//runtimes/compiler-rt:clang_rt.builtins.static)
save
end
EOF
              $(location @llvm//tools:llvm-ar) -M < "$(@D)/loongarch64-{libc}-merge.mri"
              $(location @llvm//tools:llvm-ranlib) "$@"
            """.format(libc = libc),
            tools = ["@llvm//tools:llvm-ar", "@llvm//tools:llvm-ranlib"],
        )
        native.genrule(
            name = "src_binding_release_loongarch64_unknown_linux_{}_152_2_0_release".format(libc),
            srcs = ["@v8_crate_152_2_0//:src_binding_release_aarch64_unknown_linux_gnu"],
            outs = ["src_binding_release_loongarch64-unknown-linux-{}_152_2_0.rs".format(libc)],
            cmd = " ".join([
                "$(location @rules_python//python/bin:python)",
                "$(location :loongarch64_bindings.py)",
                "--input $(location @v8_crate_152_2_0//:src_binding_release_aarch64_unknown_linux_gnu)",
                "--output $@",
            ]) + select({
                "@v8//:is_v8_enable_sandbox": " --sandbox",
                "//conditions:default": "",
            }),
            tools = [
                ":loongarch64_bindings.py",
                "@rules_python//python/bin:python",
            ],
        )
        for kind in ["release_pair", "sandbox_release_pair"]:
            native.filegroup(
                name = "rusty_v8_{}_loongarch64_unknown_linux_{}".format(kind, libc),
                srcs = [
                    ":src_binding_release_loongarch64_unknown_linux_{}_152_2_0_release".format(libc),
                    ":v8_152_2_0_loongarch64_unknown_linux_{}_release".format(libc),
                ],
            )
