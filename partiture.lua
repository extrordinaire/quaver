local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local convention = ballad.conventions
  local project = moonstone.project({ root = "." })

  local artifact = moonstone.registry.source_package(project, {
    name = project.registry_name or "moonstone/quaver",
    version = project.version,
    description = project.description,
    readme = "REGISTRY_README.md",
    include = {
      "moonstone.toml",
      "src/**",
      "docs/**",
      "README.md",
      "REGISTRY_README.md",
    },
    collect = {
      lua_modules = {
        convention.file("quaver.lua", "src/quaver.lua"),
        convention.tree("src/quaver", { prefix = "quaver" }),
      },
    },
  })

  p.sink.artifact(artifact, {
    out = "dist/registry/quaver",
    product = "package",
  })
end)
