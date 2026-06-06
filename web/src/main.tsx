import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { initObservability } from "./lib/observability";
import "./index.css";

// Sentry + PostHog (Build #5.57.1). Both no-op when their env vars
// are absent — safe to call unconditionally.
initObservability();

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing #root element in index.html");

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>
);
