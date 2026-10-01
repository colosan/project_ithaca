import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./generated/tokens.css";
import "./chrome.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
