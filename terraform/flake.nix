{
  inputs.nixpkgs.url = "nixpkgs/master";

  outputs = flakes @ { self, nixpkgs }: {

    devShell.x86_64-linux =
      with import nixpkgs { system = "x86_64-linux"; };
      mkShell {
        buildInputs = [
          (terraform.withPlugins (p: with p; [
            aws
            fastly
          ]))
        ];

        shellHook = ''
          alias tf=terraform
        '';
      };

  };

}