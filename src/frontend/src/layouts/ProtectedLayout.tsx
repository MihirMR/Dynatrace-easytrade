import { Navigate, Outlet } from "react-router"
import Navigation from "../components/Navigation"
import { AlertNotificationWatcher } from "../components/insights/AlertNotificationWatcher"
import { useAuth } from "../contexts/AuthContext/context"
import { UserContextProvider } from "../contexts/UserContext/context"

export default function ProtectedLayout() {
    const { userId, isLoggedIn, logoutHandler } = useAuth()

    if (!isLoggedIn) {
        return <Navigate to="/login" />
    }

    return (
        <UserContextProvider userId={userId} logoutHandler={logoutHandler}>
            <AlertNotificationWatcher />
            <div className="with-sidebar">
                <Navigation />
                <main className="content-area">
                    <div className="page-container">
                        <Outlet />
                    </div>
                </main>
            </div>
        </UserContextProvider>
    )
}
