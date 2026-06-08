import { useEffect, useState } from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./lib/supabase";
import { identifyUser, resetUser } from "./lib/observability";
import { LoginPage } from "./pages/LoginPage";
import { ProjectListPage } from "./pages/ProjectListPage";
import { ProjectWorkspacePage } from "./pages/ProjectWorkspacePage";
import { AdminTagLibraryPage } from "./pages/AdminTagLibraryPage";
import { AdminAIRulesPage } from "./pages/AdminAIRulesPage";
import { AdminReportBrandingPage } from "./pages/AdminReportBrandingPage";
import { AdminAIPromptTemplatesPage } from "./pages/AdminAIPromptTemplatesPage";
import { ProjectExportsPage } from "./pages/ProjectExportsPage";
import { SettingsPage } from "./pages/SettingsPage";
import { BuildInfoFooter } from "./components/BuildInfoFooter";

export function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Read current session synchronously from localStorage on mount.
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
      if (data.session?.user.id) {
        identifyUser({
          userId: data.session.user.id,
          email: data.session.user.email,
        });
      }
    });
    // Then subscribe to changes (sign-in, sign-out, token refresh).
    const { data } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
      if (newSession?.user.id) {
        identifyUser({
          userId: newSession.user.id,
          email: newSession.user.email,
        });
      } else {
        resetUser();
      }
    });
    return () => data.subscription.unsubscribe();
  }, []);

  if (loading) {
    return (
      <div className="flex h-full items-center justify-center text-neutral-500">
        Loading…
      </div>
    );
  }

  return (
    <BrowserRouter>
      <Routes>
        <Route
          path="/"
          element={session ? <Navigate to="/projects" replace /> : <LoginPage />}
        />
        <Route
          path="/projects"
          element={session ? <ProjectListPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/projects/:id/*"
          element={session ? <ProjectWorkspacePage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/admin/tag-library"
          element={session ? <AdminTagLibraryPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/admin/ai-rules"
          element={session ? <AdminAIRulesPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/admin/report-branding"
          element={session ? <AdminReportBrandingPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/admin/ai-prompt-templates"
          element={session ? <AdminAIPromptTemplatesPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/projects/:id/exports"
          element={session ? <ProjectExportsPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route
          path="/settings"
          element={session ? <SettingsPage session={session} /> : <Navigate to="/" replace />}
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      <BuildInfoFooter />
    </BrowserRouter>
  );
}
