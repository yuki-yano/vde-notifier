import eslintPlugin from "@typescript-eslint/eslint-plugin";
import parser from "@typescript-eslint/parser";

const TYPE_FILES = ["**/*.ts"];

export default [
  {
    ignores: ["dist", "coverage", "node_modules", "tsdown.config.ts", "vitest.config.ts"]
  },
  {
    files: TYPE_FILES,
    languageOptions: {
      parser,
      parserOptions: {
        project: "./tsconfig.json",
        ecmaVersion: 2022,
        sourceType: "module"
      }
    },
    plugins: {
      "@typescript-eslint": eslintPlugin
    },
    rules: {
      "no-restricted-syntax": [
        "error",
        {
          selector: "ClassDeclaration",
          message: "Classes are forbidden; use functions and objects instead."
        },
        {
          selector: "FunctionDeclaration",
          message: "Function declarations are forbidden; use arrow functions instead."
        }
      ],
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/strict-boolean-expressions": "error",
      "@typescript-eslint/prefer-function-type": "error"
    }
  }
];
