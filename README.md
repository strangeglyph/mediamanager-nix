# MediaManager-Nix

Package [MediaManager](https://github.com/maxdorninger/MediaManager) for nix consumption, and provide a minimal service module.

### Install (flakes)

Add this repository to your flake inputs:

```nix
inputs.mediamanager-nix = {
  url = "github:strangeglyph/mediamanager-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

If you just want the application:

- `mediamanager-nix.packages.${your-system}.virtual-env` contains the virtual env with all dependencies
- `mediamanager-nix.packages.${your-system}.frontend` contains the web frontend
- `mediamanager-nix.packages.${your-system}.assets` contains other required assets such as database migrations
- `mediamanager-nix.packages.${your-system}.default` contains all of the above as well as two wrapper scripts:
  - `media-manager-run-migrations` runs the database migrations
  - `media-manager-launch` uses fastapi to launch the backend
  Neither of the wrapper script will work properly without some necessary configuration, see module implementation
  for details

To use the nixos module, import it:

```nix
imports = [
  mediamanager-nix.nixosModules.default
];
```

Use as any other service. The option `service.media-manager.settings` is free-form and generates the config
file. See the [example configuration file upstream](https://github.com/maxdorninger/MediaManager/blob/master/config.example.toml) 
and the [upstream documentation](https://maxdorninger.github.io/MediaManager/configuration.html) for reference. Secrets can 
be passed as environment variables via `service.media-manager.environmentFile`; see the 
[upstream documentation](https://maxdorninger.github.io/MediaManager/configuration.html#configuring-secrets) for the 
naming scheme. Note that the env variables can contain JSON, relevant if the setting expects e.g. a list.

As a convenience, if `service.media-manager.postgres.enable` is set then a suitable local postgres database and user 
is created. The default database settings in `service.media-manager.settings` work with these.