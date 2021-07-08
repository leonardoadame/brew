# typed: true
# frozen_string_literal: true

require "extend/ENV/shared"
require "development_tools"

# ### Why `superenv`?
#
# 1. Only specify the environment we need (*NO* LDFLAGS for cmake)
# 2. Only apply compiler-specific options when we are calling that compiler
# 3. Force all incpaths and libpaths into the cc instantiation (fewer bugs)
# 4. Cater toolchain usage to specific Xcode versions
# 5. Remove flags that we don't want or that will break builds
# 6. Simpler code
# 7. Simpler formulae that *just work*
# 8. Build-system agnostic configuration of the toolchain
module Superenv
  extend T::Sig

  include SharedEnvExtension

  # @private
  attr_accessor :keg_only_deps, :deps, :run_time_deps, :x11

  sig { params(base: Superenv).void }
  def self.extended(base)
    base.keg_only_deps = []
    base.deps = []
    base.run_time_deps = []
  end

  # @private
  sig { returns(T.nilable(Pathname)) }
  def self.bin; end

  sig { void }
  def reset
    super
    # Configure scripts generated by autoconf 2.61 or later export as_nl, which
    # we use as a heuristic for running under configure
    delete("as_nl")
  end

  # @private
  sig {
    params(
      formula:         T.nilable(Formula),
      cc:              T.nilable(String),
      build_bottle:    T.nilable(T::Boolean),
      bottle_arch:     T.nilable(String),
      testing_formula: T::Boolean,
    ).void
  }
  def setup_build_environment(formula: nil, cc: nil, build_bottle: false, bottle_arch: nil, testing_formula: false)
    super
    send(compiler)

    self["HOMEBREW_ENV"] = "super"
    self["MAKEFLAGS"] ||= "-j#{determine_make_jobs}"
    self["PATH"] = determine_path
    self["PKG_CONFIG_PATH"] = determine_pkg_config_path
    self["PKG_CONFIG_LIBDIR"] = determine_pkg_config_libdir
    self["HOMEBREW_CCCFG"] = determine_cccfg
    self["HOMEBREW_OPTIMIZATION_LEVEL"] = "Os"
    self["HOMEBREW_BREW_FILE"] = HOMEBREW_BREW_FILE.to_s
    self["HOMEBREW_PREFIX"] = HOMEBREW_PREFIX.to_s
    self["HOMEBREW_CELLAR"] = HOMEBREW_CELLAR.to_s
    self["HOMEBREW_OPT"] = "#{HOMEBREW_PREFIX}/opt"
    self["HOMEBREW_TEMP"] = HOMEBREW_TEMP.to_s
    self["HOMEBREW_OPTFLAGS"] = determine_optflags
    self["HOMEBREW_ARCHFLAGS"] = ""
    self["CMAKE_PREFIX_PATH"] = determine_cmake_prefix_path
    self["CMAKE_FRAMEWORK_PATH"] = determine_cmake_frameworks_path
    self["CMAKE_INCLUDE_PATH"] = determine_cmake_include_path
    self["CMAKE_LIBRARY_PATH"] = determine_cmake_library_path
    self["ACLOCAL_PATH"] = determine_aclocal_path
    self["M4"] = "#{HOMEBREW_PREFIX}/opt/m4/bin/m4" if deps.any? { |d| d.name == "libtool" }
    self["HOMEBREW_ISYSTEM_PATHS"] = determine_isystem_paths
    self["HOMEBREW_INCLUDE_PATHS"] = determine_include_paths
    self["HOMEBREW_LIBRARY_PATHS"] = determine_library_paths
    self["HOMEBREW_DEPENDENCIES"] = determine_dependencies
    self["HOMEBREW_FORMULA_PREFIX"] = @formula.prefix unless @formula.nil?

    # The HOMEBREW_CCCFG ENV variable is used by the ENV/cc tool to control
    # compiler flag stripping. It consists of a string of characters which act
    # as flags. Some of these flags are mutually exclusive.
    #
    # O - Enables argument refurbishing. Only active under the
    #     make/bsdmake wrappers currently.
    # x - Enable C++11 mode.
    # g - Enable "-stdlib=libc++" for clang.
    # h - Enable "-stdlib=libstdc++" for clang.
    # K - Don't strip -arch <arch>, -m32, or -m64
    # d - Don't strip -march=<target>. Use only in formulae that
    #     have runtime detection of CPU features.
    # w - Pass -no_weak_imports to the linker
    #
    # These flags will also be present:
    # a - apply fix for apr-1-config path
  end
  alias generic_setup_build_environment setup_build_environment

  private

  sig { params(val: T.any(String, Pathname)).returns(String) }
  def cc=(val)
    self["HOMEBREW_CC"] = super
  end

  sig { params(val: T.any(String, Pathname)).returns(String) }
  def cxx=(val)
    self["HOMEBREW_CXX"] = super
  end

  sig { returns(String) }
  def determine_cxx
    determine_cc.to_s.gsub("gcc", "g++").gsub("clang", "clang++")
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_path
    path = PATH.new(Superenv.bin)

    # Formula dependencies can override standard tools.
    path.append(deps.map(&:opt_bin))
    path.append(homebrew_extra_paths)
    path.append("/usr/bin", "/bin", "/usr/sbin", "/sbin")

    begin
      path.append(gcc_version_formula(T.must(homebrew_cc)).opt_bin) if homebrew_cc&.match?(GNU_GCC_REGEXP)
    rescue FormulaUnavailableError
      # Don't fail and don't add these formulae to the path if they don't exist.
      nil
    end

    path.existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_pkg_config_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_pkg_config_path
    PATH.new(
      deps.map { |d| d.opt_lib/"pkgconfig" },
      deps.map { |d| d.opt_share/"pkgconfig" },
    ).existing
  end

  sig { returns(T.nilable(PATH)) }
  def determine_pkg_config_libdir
    PATH.new(
      homebrew_extra_pkg_config_paths,
    ).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_aclocal_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_aclocal_path
    PATH.new(
      keg_only_deps.map { |d| d.opt_share/"aclocal" },
      HOMEBREW_PREFIX/"share/aclocal",
      homebrew_extra_aclocal_paths,
    ).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_isystem_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_isystem_paths
    PATH.new(
      HOMEBREW_PREFIX/"include",
      homebrew_extra_isystem_paths,
    ).existing
  end

  sig { returns(T.nilable(PATH)) }
  def determine_include_paths
    PATH.new(keg_only_deps.map(&:opt_include)).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_library_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_library_paths
    paths = []
    if compiler.match?(GNU_GCC_REGEXP)
      # Add path to GCC runtime libs for version being used to compile,
      # so that the linker will find those libs before any that may be linked in $HOMEBREW_PREFIX/lib.
      # https://github.com/Homebrew/brew/pull/11459#issuecomment-851075936
      begin
        f = gcc_version_formula(compiler.to_s)
      rescue FormulaUnavailableError
        nil
      else
        paths << f.opt_lib/"gcc"/f.version.major if f.any_version_installed?
      end
    end

    paths << keg_only_deps.map(&:opt_lib)
    paths << HOMEBREW_PREFIX/"lib"

    paths += homebrew_extra_library_paths
    PATH.new(paths).existing
  end

  sig { returns(String) }
  def determine_dependencies
    deps.map(&:name).join(",")
  end

  sig { returns(T.nilable(PATH)) }
  def determine_cmake_prefix_path
    PATH.new(
      keg_only_deps.map(&:opt_prefix),
      HOMEBREW_PREFIX.to_s,
    ).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_cmake_include_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_cmake_include_path
    PATH.new(homebrew_extra_cmake_include_paths).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_cmake_library_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_cmake_library_path
    PATH.new(homebrew_extra_cmake_library_paths).existing
  end

  sig { returns(T::Array[Pathname]) }
  def homebrew_extra_cmake_frameworks_paths
    []
  end

  sig { returns(T.nilable(PATH)) }
  def determine_cmake_frameworks_path
    PATH.new(
      deps.map(&:opt_frameworks),
      homebrew_extra_cmake_frameworks_paths,
    ).existing
  end

  sig { returns(String) }
  def determine_make_jobs
    Homebrew::EnvConfig.make_jobs
  end

  sig { returns(String) }
  def determine_optflags
    Hardware::CPU.optimization_flags.fetch(effective_arch)
  rescue KeyError
    odebug "Building a bottle for custom architecture (#{effective_arch})..."
    Hardware::CPU.arch_flag(effective_arch)
  end

  sig { returns(String) }
  def determine_cccfg
    ""
  end

  public

  # Removes the MAKEFLAGS environment variable, causing make to use a single job.
  # This is useful for makefiles with race conditions.
  # When passed a block, MAKEFLAGS is removed only for the duration of the block and is restored after its completion.
  sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
  def deparallelize(&block)
    old = delete("MAKEFLAGS")
    if block
      begin
        yield
      ensure
        self["MAKEFLAGS"] = old
      end
    end

    old
  end

  sig { returns(Integer) }
  def make_jobs
    self["MAKEFLAGS"] =~ /-\w*j(\d+)/
    [Regexp.last_match(1).to_i, 1].max
  end

  sig { void }
  def permit_arch_flags
    append_to_cccfg "K"
  end

  sig { void }
  def runtime_cpu_detection
    append_to_cccfg "d"
  end

  sig { void }
  def cxx11
    append_to_cccfg "x"
    append_to_cccfg "g" if homebrew_cc == "clang"
  end

  sig { void }
  def libcxx
    append_to_cccfg "g" if compiler == :clang
  end

  # @private
  sig { void }
  def refurbish_args
    append_to_cccfg "O"
  end

  %w[O1 O0].each do |opt|
    define_method opt do |&block|
      if T.must(block)
        with_env(HOMEBREW_OPTIMIZATION_LEVEL: opt) { block.call }
      else
        send(:[]=, "HOMEBREW_OPTIMIZATION_LEVEL", opt)
      end
    end
  end
end

require "extend/os/extend/ENV/super"
