{
  description = "twitter-api-safe-proxy - Nix flake";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
  };

  outputs =
    { self, nixpkgs }:
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
            inherit (lib) mkEnableOption mkOption mkIf types;
            cfg = config.services.twitter-api-safe-proxy;
            sys = pkgs.stdenv.hostPlatform.system;
            pkg = self.packages.${sys}.twitter-api-safe-proxy or self.lib.${sys}.makeProxy { };

            settingsJson = pkgs.writeTextFile {
              name = "settings.json";
              text = builtins.toJSON cfg.settings;
            };
          in
          {
            options.services.twitter-api-safe-proxy = {
              enable = mkEnableOption "Twitter API Safe Proxy";

              settings = mkOption {
                type = types.submodule {
                  freeformType = types.attrsOf types.anything;
                  options = {
                    port = mkOption {
                      type = types.int;
                      default = 3000;
                    };
                    logLevel = mkOption {
                      type = types.enum [ "fatal" "error" "warn" "info" "debug" "trace" ];
                      default = "info";
                    };
                    logPrettyPrint = mkOption {
                      type = types.bool;
                      default = true;
                    };
                    profiles = mkOption {
                      type = types.listOf (types.submodule {
                        freeformType = types.attrsOf types.anything;
                        options = {
                          name = mkOption { type = types.str; };
                          browserType = mkOption {
                            type = types.enum [ "chromium" "firefox" "webkit" ];
                            default = "chromium";
                          };
                          browser = mkOption {
                            type = types.submodule {
                              freeformType = types.attrsOf types.anything;
                              options = {
                                headless = mkOption {
                                  type = types.bool;
                                  default = true;
                                };
                                userDataDir = mkOption {
                                  type = types.str;
                                };
                                viewport = mkOption {
                                  type = types.nullOr (types.submodule {
                                    freeformType = types.attrsOf types.anything;
                                    options = {
                                      width = mkOption {
                                        type = types.int;
                                        default = 1280;
                                      };
                                      height = mkOption {
                                        type = types.int;
                                        default = 720;
                                      };
                                    };
                                  });
                                  default = null;
                                };
                              };
                            };
                          };
                        };
                      });
                      default = [ ];
                    };
                  };
                };
                default = { };
              };

              login = {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Enable a login helper that runs the proxy with Xvfb for initial
                    X.com authentication. After login, disable this and use the
                    main service.
                  '';
                };
                display = mkOption {
                  type = types.int;
                  default = 99;
                  description = "Xvfb display number";
                };
              };
            };

            config = mkIf cfg.enable {
              systemd.services.twitter-api-safe-proxy = {
                description = "Twitter API Safe Proxy";
                wantedBy = mkIf (!cfg.login.enable) [ "multi-user.target" ];
                after = [ "network.target" ];
                environment = {
                  TWITTER_SETTINGS_FILE = settingsJson;
                };
                serviceConfig = {
                  ExecStart = "${pkg}/bin/twitter-api-safe-proxy";
                  Restart = "always";
                  RestartSec = 10;
                  DynamicUser = true;
                  StateDirectory = "twitter-api-safe-proxy";
                };
              };

              systemd.services.twitter-api-safe-proxy-login = mkIf cfg.login.enable {
                description = "Twitter API Safe Proxy Login Helper";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                environment = {
                  TWITTER_SETTINGS_FILE = settingsJson;
                };
                serviceConfig = {
                  ExecStart = "${pkgs.xvfb-run}/bin/xvfb-run -a -s '-screen 0 1280x720x24' ${pkg}/bin/twitter-api-safe-proxy";
                  Restart = "no";
                  DynamicUser = true;
                  StateDirectory = "twitter-api-safe-proxy";
                };
              };
            };
          };
      };

      formatter = forEachSystem ({ pkgs, ... }: pkgs.nixfmt);
    };
}
