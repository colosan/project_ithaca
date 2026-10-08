import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./generated/tokens.css";
import "./chrome.css";
// Pretendard (OFL-1.1) bundled so every machine and every snapshot renders the same face, installed or not.
import "pretendard/dist/web/static/pretendard-dynamic-subset.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
