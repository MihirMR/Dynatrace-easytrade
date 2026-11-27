import { IPageActions } from "@demoability/loadgen-core/lib/pageActions"
import { IVisit } from "@demoability/loadgen-core/lib/visits"
import { Logger } from "winston"
import { Page } from "puppeteer"

import { User } from "../user"

import { pageSetup } from "../helpers/common"
import { logout } from "../helpers/logout"
import {
    BoundedPageActions,
    errorName,
    isPortfolioInsightsEnabled,
    loginWithoutLoggingPassword,
    openPageAndRunOwnedAlert,
    ownedAlertFailure,
    withVisitLogger,
} from "../helpers/portfolioInsights"
import { VisitName } from "./types"

// The message names no part of the URL, since a refused URL can hold a secret.
const ORIGIN_REQUIRED =
    "EASYTRADE_URL must be an http or https origin without credentials, path, query or fragment; portfolio insights visit not run"

/**
 * Throws unless the URL is a bare http or https origin. Its serialised form
 * must be exactly the origin followed by "/", which refuses credentials, any
 * path, and any query or fragment, an empty "?" or "#" included. The URL feeds
 * the page cookie, the logs, the flag read, the page and the cleanup request,
 * so a value that can carry a secret stops the visit before any of them; the
 * worker counts the error as a failed visit.
 */
function requireCredentialFreeOrigin(url: URL): void {
    const isHttp = url.protocol === "http:" || url.protocol === "https:"
    if (!isHttp || url.href !== `${url.origin}/`) {
        throw new Error(ORIGIN_REQUIRED)
    }
}

export class PortfolioInsightsAlertVisit implements IVisit {
    readonly visitName: VisitName
    readonly url: URL
    readonly user: User
    private readonly fetchFn: typeof fetch
    private readonly random: () => number

    constructor(
        visitName: VisitName,
        url: URL,
        user: User,
        deps: { fetchFn?: typeof fetch; random?: () => number } = {}
    ) {
        this.visitName = visitName
        this.url = url
        this.user = user
        this.fetchFn = deps.fetchFn ?? fetch
        this.random = deps.random ?? Math.random
    }

    getName(): string {
        return this.visitName
    }

    async setup(pageActions: IPageActions, logger: Logger): Promise<void> {
        // The worker calls setup before run, and page setup sets a cookie for
        // the URL's host, so the URL is checked before anything uses it.
        requireCredentialFreeOrigin(this.url)
        logger.info(
            `Setting up page for user [${this.user.username}|${this.user.ip4}]`
        )
        await pageActions.setupPage(async (page: Page) => {
            await pageSetup(page, this.user, this.url)
        })
    }

    async run(pageActions: IPageActions, logger: Logger): Promise<void> {
        // Checked again because run does not depend on setup having run.
        requireCredentialFreeOrigin(this.url)

        const enabled = await withVisitLogger(logger, () =>
            isPortfolioInsightsEnabled(this.url, this.fetchFn)
        )
        if (!enabled) {
            logger.info(
                "Flag [portfolio-insights-enabled] is off, skipping portfolio insights visit"
            )
            return
        }

        // Every element action from here on ends at its deadline and
        // dispatches no click, selection or write after it, so a control that
        // never scrolls into view cannot hold the visit or the cleanup and
        // logout after it, and an abandoned action cannot run late.
        const boundedActions = new BoundedPageActions(pageActions, logger)

        logger.info(`Going to EasyTrade frontend at [${this.url.origin}]`)
        await boundedActions.gotoPage(this.url.toString())

        // The login writes each credential only into a field whose document
        // is at this origin, checked in the same step in the page as the
        // write, so a redirect elsewhere fails the visit with nothing written,
        // before there is a session to close.
        logger.info(`Logging in as user [${this.user.username}]`)
        await loginWithoutLoggingPassword(boundedActions, this.user, this.url)

        // Logged in from here on, so the session is closed whatever happens.
        // The visit then fails with the first error, or when its own alert
        // did not end clean: the worker counts only a normal return as success.
        let failure: { error: unknown } | undefined
        try {
            logger.info("Opening portfolio insights page")
            const outcome = await openPageAndRunOwnedAlert(
                boundedActions,
                this.url,
                logger,
                { fetchFn: this.fetchFn, random: this.random }
            )
            const unclean = ownedAlertFailure(outcome)
            if (unclean !== undefined) {
                failure = { error: unclean }
            }
        } catch (error) {
            failure = { error }
        }

        try {
            await this.closeSession(boundedActions, logger)
        } catch (error) {
            if (failure === undefined) {
                throw error
            }
            logger.warn("Closing the session after a failed visit failed", {
                error,
            })
        }
        if (failure !== undefined) {
            throw failure.error
        }
    }

    /**
     * Logs out, then ends the Dynatrace session, also when logging out failed,
     * and fails with the first error: the logout's, otherwise the session
     * end's. A session end that fails after a failed logout is logged at warn,
     * the message naming only the error's name and the entry carrying the
     * error object, so neither failure is lost.
     */
    private async closeSession(
        pageActions: IPageActions,
        logger: Logger
    ): Promise<void> {
        logger.info(`Logging out user [${this.user.username}]`)
        let logoutFailure: { error: unknown } | undefined
        try {
            await logout(pageActions)
        } catch (error) {
            logoutFailure = { error }
        }

        logger.info("Attempting to end dynatrace session")
        try {
            await pageActions.endDtSession()
        } catch (error) {
            if (logoutFailure === undefined) {
                throw error
            }
            logger.warn(
                `Ending the dynatrace session failed after the logout failed: error [${errorName(error)}]`,
                { error }
            )
        }
        if (logoutFailure !== undefined) {
            throw logoutFailure.error
        }
    }
}
