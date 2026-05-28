{
  description = "twitter-api-safe-proxy - Nix flake";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, sops-nix }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
      });

      defaultSettings = {
        port = 3000;
        logLevel = "info";
        logPrettyPrint = true;
        profiles = [ ];
      };
    in
    {

      lib = forEachSystem (
        { pkgs, ... }:
        let
          pnpmDeps = pkgs.fetchPnpmDeps {
            pname = "twitter-api-safe";
            version = "1.0.0";
            src = self;
            hash = "sha256-1pz1qYU82mFrUEPA/YvgijfHzQweA6EcrkIv0zcAa9g=";
            fetcherVersion = 3;
          };

          built = pkgs.stdenv.mkDerivation {
            pname = "twitter-api-safe";
            version = "1.0.0";
            src = self;

            nativeBuildInputs = [
              pkgs.pnpmConfigHook
              pkgs.nodejs_24
              pkgs.pnpm
              pkgs.jq
            ];

            inherit pnpmDeps;

            buildPhase = ''
              runHook preBuild
              jq 'del(.packageManager)' package.json > package.json.tmp
              mv package.json.tmp package.json
              pnpm run --filter twitter-api-safe-request build
              pnpm run --filter twitter-api-safe-proxy build
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r packages $out/
              cp -r node_modules $out/
              echo '{}' > $out/settings.json
              runHook postInstall
            '';
          };

          pwBrowsers = pkgs.runCommand "pw-browsers" { } ''
            mkdir -p $out
            BROWSERS="${pkgs.playwright-driver.browsers}"
            for dir in $BROWSERS/chromium-*; do
              ln -sfn "$dir" "$out/chromium-1223"
            done
            for dir in $BROWSERS/chromium_headless_shell-*; do
              ln -sfn "$dir" "$out/chromium_headless_shell-1223"
            done
            for dir in $BROWSERS/ffmpeg-*; do
              ln -sfn "$dir" "$out/ffmpeg-1011"
            done
          '';

          mkSettings =
            settings:
            pkgs.writeTextFile {
              name = "settings.json";
              text = builtins.toJSON (defaultSettings // settings);
            };

          mkRuntime =
            settings:
            pkgs.runCommand "twitter-api-safe-runtime" { } ''
              mkdir -p $out
              cp -r ${built}/node_modules $out/node_modules
              cp -r ${built}/packages $out/packages
              cp ${mkSettings settings} $out/settings.json
            '';
        in
        {
          makeProxy =
            { settings ? { } }:
            pkgs.writeShellApplication {
              name = "twitter-api-safe-proxy";
              runtimeInputs = with pkgs; [ nodejs_24 playwright-driver.browsers ];
              text = ''
                export PLAYWRIGHT_BROWSERS_PATH=${pwBrowsers}
                export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
                RUNTIME=${mkRuntime settings}
                if [ -n "''${TWITTER_SETTINGS_FILE:-}" ]; then
                  cp "$TWITTER_SETTINGS_FILE" "$RUNTIME/settings.json"
                fi
                [ -z "''${TWITTER_USER_DATA_DIR:-}" ] && export TWITTER_USER_DATA_DIR="$HOME/.twitter-api-safe-proxy/user_data"
                mkdir -p "$TWITTER_USER_DATA_DIR"
                cd $RUNTIME/packages/server
                exec node dist/server.js
              '';
            };

          makeDebug =
            { settings ? { } }:
            pkgs.writeShellApplication {
              name = "twitter-api-safe-debug";
              runtimeInputs = with pkgs; [ nodejs_24 playwright-driver.browsers ];
              text = ''
                export PLAYWRIGHT_BROWSERS_PATH=${pwBrowsers}
                export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
                cd ${mkRuntime settings}/packages/server
                exec node dist/dashboard/server.js
              '';
            };
        }
      );

      packages = forEachSystem (
        { pkgs, system }:
        let
          lib = self.lib.${system};
          proxy = lib.makeProxy { };
          debug = lib.makeDebug { };
        in
        {
          twitter-api-safe-proxy = proxy;
          twitter-api-safe-debug = debug;
          default = proxy;
        }
      );

      devShells = forEachSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              nodejs_24
              pnpm
              playwright-driver.browsers
              self.formatter.${system}
            ];

            shellHook = ''
              NIX_PW_BROWSERS=''${PLAYWRIGHT_BROWSERS_DIR:-/tmp/pw-browsers}
              rm -rf "$NIX_PW_BROWSERS"
              mkdir -p "$NIX_PW_BROWSERS"
              ln -sfn ${pkgs.playwright-driver.browsers}/chromium-* "$NIX_PW_BROWSERS/chromium-1223"
              ln -sfn ${pkgs.playwright-driver.browsers}/chromium_headless_shell-* "$NIX_PW_BROWSERS/chromium_headless_shell-1223"
              ln -sfn ${pkgs.playwright-driver.browsers}/ffmpeg-* "$NIX_PW_BROWSERS/ffmpeg-1011"
              export PLAYWRIGHT_BROWSERS_PATH="$NIX_PW_BROWSERS"
              export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
            '';
          };
        }
      );

      nixosModules = {
        proxy =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            cfg = config.services.twitter-api-safe-proxy;
            sys = pkgs.stdenv.hostPlatform.system;
            pkg = self.packages.${sys}.twitter-api-safe-proxy or self.lib.${sys}.makeProxy { };
          in
          {
            imports = [ sops-nix.nixosModules.sops ];

            options.services.twitter-api-safe-proxy = {
              enable = lib.mkEnableOption "Twitter API Safe Proxy";

              sopsSettingsFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Path to sops-decrypted settings.json";
              };

              settingsFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Path to plaintext settings.json (alternative to sopsSettingsFile)";
              };
            };

            config = lib.mkIf cfg.enable {
              systemd.services.twitter-api-safe-proxy = {
                description = "Twitter API Safe Proxy";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  ExecStart = "${pkg}/bin/twitter-api-safe-proxy";
                  Restart = "always";
                  RestartSec = 10;
                  DynamicUser = true;
                  StateDirectory = "twitter-api-safe-proxy";
                } // lib.optionalAttrs (cfg.sopsSettingsFile != null) {
                  Environment = [
                    "TWITTER_SETTINGS_FILE=${cfg.sopsSettingsFile}"
                  ];
                } // lib.optionalAttrs (cfg.settingsFile != null) {
                  Environment = [
                    "TWITTER_SETTINGS_FILE=${cfg.settingsFile}"
                  ];
                };
              };
            };
          };
      };

      formatter = forEachSystem ({ pkgs, ... }: pkgs.nixfmt);
    };
}
