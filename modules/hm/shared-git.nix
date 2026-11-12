_:
{
  flake.modules.homeManager.shared-git = _: {
    programs.difftastic = {
      enable = true;
      git.enable = true;
    };
    programs.git = {
      enable = true;
      settings = {
        user = {
          name = "Andreas Wurzer";
        };
        diff.tool = "nvimdiff";
        merge.tool = "nvimdiff";
        init.defaultBranch = "main";
        difftool = {
          prompt = false;
        };
      };
      includes = [
        {
          condition = "hasconfig:remote.*.url:git@github.com:*/**";
          contents = {
            user = {
              email = "389365+andeee@users.noreply.github.com";
            };
          };
        }
      ];
    };
  };
}
