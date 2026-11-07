// The bundled alternatives catalog of Port to Pi (docs/design/skill-port.md, "Alternatives catalog").
// Data only: families of interchangeable tools, their detection tokens and known pairwise rules.
// Kept as a string, not a resource bundle, because the standalone `akit` binary ships without one.
// Users add entries in ~/.akit/port-presets/catalog.json (same format).
let bundledPortCatalog = #"""
{
  "families": [
    {
      "id": "test-framework", "title": "test framework",
      "members": [
        {"id": "vitest", "title": "Vitest", "tokens": ["\\bvitest\\b", "(?<![\\w.])vi\\.(?:fn|spyOn|mock|useFakeTimers)\\b"], "forbid": ["vi.", "vitest"]},
        {"id": "jest", "title": "Jest", "tokens": ["(?<![\\w@/])jest\\.(?:fn|spyOn|mock|config)\\b", "@jest/globals", "\\bnpx jest\\b"], "forbid": ["jest."]},
        {"id": "mocha", "title": "Mocha", "tokens": ["\\bmocha\\b"], "forbid": ["mocha"]},
        {"id": "bun-test", "title": "bun test", "tokens": ["\\bbun test\\b", "from ['\"]bun:test['\"]"], "forbid": ["bun:test", "bun test"]}
      ],
      "pairs": [
        {"from": "vitest", "to": "jest", "rules": "vi.fn( => jest.fn(\nvi.spyOn( => jest.spyOn(\nvi.mock( => jest.mock(\nvi.unmock( => jest.unmock(\nvi.useFakeTimers( => jest.useFakeTimers(\nvi.useRealTimers( => jest.useRealTimers(\nvi.advanceTimersByTime( => jest.advanceTimersByTime(\nvi.runAllTimers( => jest.runAllTimers(\nvi.clearAllMocks( => jest.clearAllMocks(\nvi.resetAllMocks( => jest.resetAllMocks(\nvi.restoreAllMocks( => jest.restoreAllMocks(\nvi.importActual( => jest.requireActual(\nre:from\\s+(['\"])vitest\\1 => from '@jest/globals'\nvitest.config => jest.config\nnpx vitest run => npx jest\nnpx vitest => npx jest\nnote: Use Jest instead of Vitest everywhere: imports, config file names, commands, mocks and timers.\nnote: vi.importActual is async and jest.requireActual is not: drop the await in front of it.\nnote: vi.hoisted has no Jest counterpart: move its values into the jest.mock factory.\nnote: Vitest's in-source tests (import.meta.vitest) have no Jest counterpart: move them into a test file.\nforbid: vi.\nforbid: vitest"}
      ]
    },
    {
      "id": "package-manager", "title": "package manager",
      "members": [
        {"id": "npm", "title": "npm", "tokens": ["\\bnpm (?:install|i|run|ci|test|exec)\\b", "\\bnpx\\b"], "forbid": ["npm ", "npx "]},
        {"id": "pnpm", "title": "pnpm", "tokens": ["\\bpnpm (?:install|i|add|run|test|exec|dlx)\\b"], "forbid": ["pnpm "]},
        {"id": "yarn", "title": "Yarn", "tokens": ["\\byarn (?:install|add|run|test|dlx)\\b"], "forbid": ["yarn "]},
        {"id": "bun", "title": "Bun", "tokens": ["\\bbun (?:install|add|run|x)\\b", "\\bbunx\\b"], "forbid": ["bun ", "bunx "]}
      ],
      "pairs": [
        {"from": "npm", "to": "pnpm", "rules": "npm run => pnpm run\nnpm test => pnpm test\nnpm ci => pnpm install --frozen-lockfile\nre:\\bnpm (?:install|i) (\\S) => pnpm add $1\nre:\\bnpm (?:install|i)\\b => pnpm install\nre:\\bnpx\\b => pnpm dlx\npackage-lock.json => pnpm-lock.yaml\nnote: Use pnpm for every package command; lock file pnpm-lock.yaml.\nforbid: npm \nforbid: npx \nforbid: package-lock.json"},
        {"from": "npm", "to": "yarn", "rules": "npm run => yarn run\nnpm test => yarn test\nre:\\bnpm (?:install|i) (\\S) => yarn add $1\nre:\\bnpm (?:install|i)\\b => yarn install\nre:\\bnpx\\b => yarn dlx\npackage-lock.json => yarn.lock\nforbid: npm \nforbid: npx \nforbid: package-lock.json"},
        {"from": "npm", "to": "bun", "rules": "npm run => bun run\nnpm test => bun test\nre:\\bnpm (?:install|i) (\\S) => bun add $1\nre:\\bnpm (?:install|i)\\b => bun install\nre:\\bnpx\\b => bunx\npackage-lock.json => bun.lock\nforbid: npm \nforbid: npx \nforbid: package-lock.json"}
      ]
    },
    {
      "id": "http-client", "title": "HTTP client",
      "members": [
        {"id": "axios", "title": "axios", "tokens": ["\\baxios\\b"], "forbid": ["axios"]},
        {"id": "fetch", "title": "fetch", "tokens": ["(?<![\\w.])fetch\\("], "forbid": ["fetch("]},
        {"id": "got", "title": "got", "tokens": ["from ['\"]got['\"]"], "forbid": ["got."]},
        {"id": "ky", "title": "ky", "tokens": ["from ['\"]ky['\"]"], "forbid": ["ky."]}
      ],
      "pairs": [
        {"from": "axios", "to": "fetch", "rules": "re:import axios from ['\"]axios['\"];?\\n? => \nre:axios\\.get\\( => fetch(\nnote: Use the built-in fetch instead of axios: no import, check response.ok and call response.json() yourself; fetch doesn't throw on HTTP errors.\nnote: axios.post(url, body) becomes fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).\nforbid: axios"}
      ]
    },
    {
      "id": "logger", "title": "logger",
      "members": [
        {"id": "winston", "title": "winston", "tokens": ["\\bwinston\\b"], "forbid": ["winston"]},
        {"id": "pino", "title": "pino", "tokens": ["\\bpino\\b"], "forbid": ["pino"]}
      ],
      "pairs": []
    },
    {
      "id": "linter", "title": "linter and formatter",
      "members": [
        {"id": "eslint", "title": "ESLint", "tokens": ["\\beslint\\b"], "forbid": ["eslint"]},
        {"id": "prettier", "title": "Prettier", "tokens": ["\\bprettier\\b"], "forbid": ["prettier"]},
        {"id": "biome", "title": "Biome", "tokens": ["\\bbiome\\b"], "forbid": ["biome"]}
      ],
      "pairs": []
    },
    {
      "id": "orm", "title": "ORM",
      "members": [
        {"id": "prisma", "title": "Prisma", "tokens": ["\\bprisma\\b"], "forbid": ["prisma"]},
        {"id": "drizzle", "title": "Drizzle", "tokens": ["\\bdrizzle\\b"], "forbid": ["drizzle"]},
        {"id": "typeorm", "title": "TypeORM", "tokens": ["\\btypeorm\\b"], "forbid": ["typeorm"]}
      ],
      "pairs": []
    },
    {
      "id": "ci", "title": "CI",
      "members": [
        {"id": "github-actions", "title": "GitHub Actions", "tokens": ["\\.github/workflows", "\\bgh run\\b"], "forbid": [".github/workflows"]},
        {"id": "gitlab-ci", "title": "GitLab CI", "tokens": ["\\.gitlab-ci\\.yml", "\\bglab ci\\b"], "forbid": [".gitlab-ci.yml"]}
      ],
      "pairs": []
    },
    {
      "id": "python-env", "title": "Python package tool",
      "members": [
        {"id": "pip", "title": "pip", "tokens": ["\\bpip install\\b"], "forbid": ["pip install"]},
        {"id": "uv", "title": "uv", "tokens": ["\\buv (?:pip|run|add|sync)\\b"], "forbid": ["uv "]},
        {"id": "poetry", "title": "Poetry", "tokens": ["\\bpoetry (?:add|install|run)\\b"], "forbid": ["poetry "]}
      ],
      "pairs": []
    }
  ]
}
"""#
