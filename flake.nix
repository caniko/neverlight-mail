{
  description = "Neverlight Mail — a COSMIC desktop email client";

  inputs = {
    rs-harbor.url = "git+https://codeberg.org/caniko/rs-harbor.git?ref=trunk";
    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
    flake-utils.url = "github:numtide/flake-utils";

    # These crates are private path dependencies of the application and are
    # intentionally composed into the build source tree below.
    neverlight-mail-core = {
      url = "github:jstelzer/neverlight-mail-core";
      flake = false;
    };
    neverlight-mail-oauth = {
      url = "github:jstelzer/neverlight-mail-oauth";
      flake = false;
    };
    neverlight-mail-html-safe-md = {
      url = "github:jstelzer/neverlight-mail-html-safe-md";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    rs-harbor,
    rust-overlay,
    flake-utils,
    neverlight-mail-core,
    neverlight-mail-oauth,
    neverlight-mail-html-safe-md,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    homeModule = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.programs.neverlight-mail;
      json = pkgs.formats.json {};
      accountModule = {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            description = "Stable Neverlight account id used for keyring entries.";
          };
          label = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Human-readable account label.";
          };
          publicUrl = lib.mkOption {
            type = lib.types.str;
            description = "Public Stalwart URL hosting the OAuth authorization server.";
          };
          jmapUrl = lib.mkOption {
            type = lib.types.str;
            description = "JMAP session resource URL.";
          };
          username = lib.mkOption {
            type = lib.types.str;
            description = "Mail account username.";
          };
          clientId = lib.mkOption {
            type = lib.types.str;
            default = "neverlight-mail";
            description = "Pre-registered Stalwart OAuth client id.";
          };
          redirectUri = lib.mkOption {
            type = lib.types.str;
            default = "http://127.0.0.1:49152/callback";
            description = "Exact loopback callback URI registered for this client.";
          };
          emailAddresses = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Addresses associated with the account.";
          };
          maxMessagesPerMailbox = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "Optional backfill limit per mailbox.";
          };
        };
      };
      configFile = json.generate "neverlight-mail-config.json" {
        accounts = lib.mapAttrsToList (name: account:
          {
            id = account.id;
            label =
              if account.label == ""
              then name
              else account.label;
            jmap_url = account.jmapUrl;
            username = account.username;
            managed = true;
            auth = {
              backend = "oauth";
              issuer = account.publicUrl;
              client_id = account.clientId;
              resource = account.jmapUrl;
              token_endpoint = "${account.publicUrl}/auth/token";
              redirect_uri = account.redirectUri;
            };
            email_addresses = account.emailAddresses;
            capabilities = {};
          }
          // lib.optionalAttrs (account.maxMessagesPerMailbox != null) {
            max_messages_per_mailbox = account.maxMessagesPerMailbox;
          })
        cfg.accounts;
      };
    in {
      options.programs.neverlight-mail = {
        enable = lib.mkEnableOption "Neverlight Mail";
        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          defaultText = lib.literalExpression "self.packages.<system>.default";
          description = "Package to install for Neverlight Mail.";
        };
        accounts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule accountModule);
          default = {};
          description = "Declarative OAuth accounts. Refresh tokens remain in the OS keyring.";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.accounts != {};
            message = "programs.neverlight-mail.accounts must contain at least one declarative account.";
          }
        ];
        home.packages = [cfg.package];
        xdg.configFile."neverlight-mail/config.json".source = configFile;
      };
    };
  in
    (flake-utils.lib.eachSystem systems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };
      toolchain = rs-harbor.lib.mkToolchain {
        inherit pkgs;
        # The upstream CI uses stable; keep the package reproducible without
        # requiring nightly-only compiler behavior.
        channel = "stable";
        extensions = ["rust-src" "rustfmt" "llvm-tools-preview"];
        withRustAnalyzer = false;
      };
      inherit (toolchain) craneLib;
      cross = rs-harbor.lib.mkCross {
        inherit pkgs system;
        enableOsxcross = false;
      };
      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
      siblingSetup = ''
        cp -r --no-preserve=mode ${neverlight-mail-core} "$NIX_BUILD_TOP/neverlight-mail-core"
        cp -r --no-preserve=mode ${neverlight-mail-oauth} "$NIX_BUILD_TOP/neverlight-mail-oauth"
        cp -r --no-preserve=mode ${neverlight-mail-html-safe-md} "$NIX_BUILD_TOP/neverlight-mail-html-safe-md"
      '';
      src = craneLib.cleanCargoSource ./.;
      commonArgs = {
        inherit src;
        pname = cargoToml.package.name;
        version = cargoToml.package.version;
        strictDeps = true;
        postUnpack = siblingSetup;
        cargoExtraArgs = "-p neverlight-mail";
        nativeBuildInputs = [pkgs.libcosmicAppHook];
        buildInputs = [
          pkgs.dbus
          pkgs.fontconfig
          pkgs.freetype
          pkgs.libinput
        ];
      };
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;
      package = craneLib.buildPackage (commonArgs
        // {
          inherit cargoArtifacts;
          postInstall = ''
            install -Dm644 ${./resources/com.neverlight.email.desktop} \
              "$out/share/applications/com.neverlight.email.desktop"
            install -Dm644 ${./resources/com.neverlight.email.metainfo.xml} \
              "$out/share/metainfo/com.neverlight.email.metainfo.xml"
            mkdir -p "$out/share/icons"
            cp -r --no-preserve=mode ${./resources/icons}/. "$out/share/icons/"
          '';
          meta = {
            description = "A COSMIC desktop email client";
            homepage = "https://github.com/jstelzer/neverlight-mail";
            license = [pkgs.lib.licenses.mit pkgs.lib.licenses.asl20];
            mainProgram = "neverlight-mail";
            platforms = pkgs.lib.platforms.linux;
          };
        });
    in {
      packages.default = package;

      checks = {
        default = package;
        clippy = craneLib.cargoClippy (commonArgs
          // {
            inherit cargoArtifacts;
            # The upstream snapshot has these two existing lints; keep the
            # check strict for all other warnings without changing Rust code.
            cargoClippyExtraArgs = "--all-targets -- -D warnings -A clippy::too_many_arguments -A clippy::unnecessary_map_or";
          });
        fmt = craneLib.cargoFmt {
          inherit src;
          postUnpack = siblingSetup;
        };
      };

      devShells.default =
        (rs-harbor.lib.mkDevShell {
          inherit pkgs craneLib cross;
          enableWindowsEnv = false;
          enableOsxcrossEnv = false;
          checks = self.checks.${system};
          packages = [pkgs.libcosmicAppHook] ++ commonArgs.buildInputs;
        }).overrideAttrs (old: {
          shellHook =
            (old.shellHook or "")
            + ''
              for source in \
                ${neverlight-mail-core}:neverlight-mail-core \
                ${neverlight-mail-oauth}:neverlight-mail-oauth \
                ${neverlight-mail-html-safe-md}:neverlight-mail-html-safe-md
              do
                target="$(dirname "$PWD")/''${source#*:}"
                test -e "$target" || cp -r --no-preserve=mode "''${source%%:*}" "$target"
              done
            '';
        });
    }))
    // {
      homeModules.default = homeModule;
    };
}
