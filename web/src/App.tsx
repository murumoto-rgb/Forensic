import { lazy, Suspense, useEffect, useState } from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./lib/supabase";
import { identifyUser, resetUser } from "./lib/observability";
// Hot-path pages: stay in the main bundle so the login → list flow
// doesn't pay a chunk fetch on the first click.
import { LoginPage } from "./pages/LoginPage";
import { ProjectListPage } from "./pages/ProjectListPage";
import { BuildInfoFooter } from "./components/BuildInfoFooter";

// Build #6.16.1: route-level code splitting. The workspace pulls in
// `react-konva`, the photo preview panel (1.6k lines), and the markup
// canvas; the five admin pages each weigh ~50–80 kB of editor code
// most users never load. Lazy chunks shave the main bundle and let
// the browser cache admin pages per-page instead of re-downloading
// the whole app on a tag-library tweak.
const ProjectWorkspacePage = lazy(() =>
  import("./pages/ProjectWorkspacePage").then((m) => ({
    default: m.ProjectWorkspacePage,
  }))
);
const AdminTagLibraryPage = lazy(() =>
  import("./pages/AdminTagLibraryPage").then((m) => ({
    default: m.AdminTagLibraryPage,
  }))
);
const AdminUsersPage = lazy(() =>
  import("./pages/AdminUsersPage").then((m) => ({
    default: m.AdminUsersPage,
  }))
);
const AdminAIRulesPage = lazy(() =>
  import("./pages/AdminAIRulesPage").then((m) => ({
    default: m.AdminAIRulesPage,
  }))
);
const AdminReportBrandingPage = lazy(() =>
  import("./pages/AdminReportBrandingPage").then((m) => ({
    default: m.AdminReportBrandingPage,
  }))
);
const AdminAIPromptTemplatesPage = lazy(() =>
  import("./pages/AdminAIPromptTemplatesPage").then((m) => ({
    default: m.AdminAIPromptTemplatesPage,
  }))
);
const ProjectExportsPage = lazy(() =>
  import("./pages/ProjectExportsPage").then((m) => ({
    default: m.ProjectExportsPage,
  }))
);
const SettingsPage = lazy(() =>
  import("./pages/SettingsPage").then((m) => ({ default: m.SettingsPage }))
);

function RouteSuspense({ children }: { children: React.ReactNode }) {
  return (
    <Suspense
      fallback={
        <div className="flex h-screen items-center justify-center text-neutral-500">
          Loading…
        </div>
      }
    >
      {children}
    </Suspense>
  );
}

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
          element={
            session ? (
              <RouteSuspense>
                <ProjectWorkspacePage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/admin/tag-library"
          element={
            session ? (
              <RouteSuspense>
                <AdminTagLibraryPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/admin/ai-rules"
          element={
            session ? (
              <RouteSuspense>
                <AdminAIRulesPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/admin/report-branding"
          element={
            session ? (
              <RouteSuspense>
                <AdminReportBrandingPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/admin/ai-prompt-templates"
          element={
            session ? (
              <RouteSuspense>
                <AdminAIPromptTemplatesPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/admin/users"
          element={
            session ? (
              <RouteSuspense>
                <AdminUsersPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/projects/:id/exports"
          element={
            session ? (
              <RouteSuspense>
                <ProjectExportsPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route
          path="/settings"
          element={
            session ? (
              <RouteSuspense>
                <SettingsPage session={session} />
              </RouteSuspense>
            ) : (
              <Navigate to="/" replace />
            )
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      <BuildInfoFooter />
    </BrowserRouter>
  );
}
