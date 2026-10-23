import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "../../workbench/src/generated/tokens.css";
import "./app.css";
// Pretendard (OFL-1.1), bundled like the workbench so the app and the prototypes render the same face.
import "pretendard/dist/web/static/pretendard-dynamic-subset.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
