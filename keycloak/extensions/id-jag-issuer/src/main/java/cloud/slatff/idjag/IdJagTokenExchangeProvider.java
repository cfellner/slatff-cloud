package cloud.slatff.idjag;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import org.keycloak.OAuthErrorException;
import org.keycloak.common.util.Time;
import org.keycloak.crypto.Algorithm;
import org.keycloak.crypto.SignatureProvider;
import org.keycloak.events.EventBuilder;
import org.keycloak.jose.jws.JWSBuilder;
import org.keycloak.jose.jws.JWSInput;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.protocol.oidc.TokenExchangeContext;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.representations.IDToken;
import org.keycloak.services.CorsErrorResponseException;
import org.keycloak.services.Urls;
import org.keycloak.services.cors.Cors;

/**
 * Issues an Identity Assertion JWT Authorization Grant (ID-JAG),
 * draft-ietf-oauth-identity-assertion-authz-grant-06, section 4.3.
 *
 * Request (token endpoint of this realm, client authenticated):
 *   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
 *   requested_token_type=urn:ietf:params:oauth:token-type:id-jag
 *   audience=<issuer of the Resource Authorization Server>   (exactly one)
 *   resource=<resource>                                       (optional)
 *   scope=<scopes>                                            (optional)
 *   subject_token=<ID token issued by this realm to this client>
 *   subject_token_type=urn:ietf:params:oauth:token-type:id_token
 *
 * Policy, set as attributes on the requesting client:
 *   id-jag.audiences      space-separated Resource AS issuers this client may target (required)
 *   id-jag.scopes         space-separated scopes it may get; others are dropped
 *   id-jag.resources      space-separated resources it may name
 *   id-jag.required-role  realm role the user must have
 *   id-jag.client-id      client id at the Resource AS (default: same client id)
 *   id-jag.lifespan       seconds, default 300
 */
public class IdJagTokenExchangeProvider implements TokenExchangeProvider {

    static final String ID_JAG_TYPE = "urn:ietf:params:oauth:token-type:id-jag";
    static final String ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token";
    static final String ID_JAG_HEADER_TYPE = "oauth-id-jag+jwt";
    static final String INVALID_TARGET = "invalid_target";
    static final String ACCESS_DENIED = "access_denied";

    @Override
    public boolean supports(TokenExchangeContext context) {
        return ID_JAG_TYPE.equals(context.getParams().getRequestedTokenType());
    }

    @Override
    public Response exchange(TokenExchangeContext ctx) {
        KeycloakSession session = ctx.getSession();
        RealmModel realm = ctx.getRealm();
        ClientModel client = ctx.getClient();
        EventBuilder event = ctx.getEvent();
        Cors cors = ctx.getCors();
        event.detail("requested_token_type", ID_JAG_TYPE);

        // 1. Client policy must exist: no audiences configured means this client may not ask.
        Set<String> allowedAudiences = words(client.getAttribute("id-jag.audiences"));
        if (allowedAudiences.isEmpty()) {
            throw fail(cors, event, ACCESS_DENIED, "client is not allowed to request ID-JAGs", Response.Status.FORBIDDEN);
        }

        // 2. Subject token: an ID token, issued by this realm, to this client, still valid.
        if (!ID_TOKEN_TYPE.equals(ctx.getParams().getSubjectTokenType())) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST,
                    "subject_token_type must be " + ID_TOKEN_TYPE, Response.Status.BAD_REQUEST);
        }
        String subjectToken = ctx.getParams().getSubjectToken();
        if (subjectToken == null) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "subject_token is required", Response.Status.BAD_REQUEST);
        }
        String headerType;
        try {
            headerType = new JWSInput(subjectToken).getHeader().getType();
        } catch (Exception e) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "subject_token is not a JWT", Response.Status.BAD_REQUEST);
        }
        if (headerType != null && !"JWT".equalsIgnoreCase(headerType)) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST,
                    "subject_token header typ '" + headerType + "' is not an ID token", Response.Status.BAD_REQUEST);
        }
        IDToken id = session.tokens().decode(subjectToken, IDToken.class);
        if (id == null) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "subject_token signature is not valid", Response.Status.BAD_REQUEST);
        }
        if (!"ID".equals(id.getType())) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST,
                    "subject_token is not an ID token (typ " + id.getType() + ")", Response.Status.BAD_REQUEST);
        }
        String issuer = Urls.realmIssuer(session.getContext().getUri().getBaseUri(), realm.getName());
        if (!issuer.equals(id.getIssuer())) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "subject_token was not issued by this realm", Response.Status.BAD_REQUEST);
        }
        if (id.getExp() == null || id.getExp() <= Time.currentTime()) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "subject_token has expired", Response.Status.BAD_REQUEST);
        }
        if (!id.hasAudience(client.getClientId())) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST,
                    "subject_token audience does not match the authenticated client", Response.Status.BAD_REQUEST);
        }
        UserModel user = session.users().getUserById(realm, id.getSubject());
        if (user == null || !user.isEnabled()) {
            throw fail(cors, event, ACCESS_DENIED, "user not found or disabled", Response.Status.FORBIDDEN);
        }
        event.user(user);
        String sid = id.getSessionId();
        if (sid != null && session.sessions().getUserSession(realm, sid) == null) {
            throw fail(cors, event, ACCESS_DENIED, "the user's session has ended", Response.Status.FORBIDDEN);
        }

        // 3. Audience: exactly one, and trusted for this client.
        List<String> audience = ctx.getParams().getAudience();
        if (audience == null || audience.size() != 1) {
            throw fail(cors, event, OAuthErrorException.INVALID_REQUEST, "exactly one audience is required", Response.Status.BAD_REQUEST);
        }
        String aud = audience.get(0);
        if (!allowedAudiences.contains(aud)) {
            throw fail(cors, event, INVALID_TARGET, "audience is not a trusted Resource Authorization Server for this client",
                    Response.Status.BAD_REQUEST);
        }
        event.detail("audience", aud);

        // 4. User policy.
        String requiredRole = client.getAttribute("id-jag.required-role");
        if (requiredRole != null && !requiredRole.isBlank()) {
            RoleModel role = realm.getRole(requiredRole.trim());
            if (role == null || !user.hasRole(role)) {
                throw fail(cors, event, ACCESS_DENIED, "user does not have role " + requiredRole.trim(), Response.Status.FORBIDDEN);
            }
        }

        // 5. Resources (RFC 8707): keep those allowed, exactly as sent.
        List<String> requestedResources = ctx.getParams().getResource();
        List<String> grantedResources = new ArrayList<>();
        if (requestedResources != null && !requestedResources.isEmpty()) {
            Set<String> allowedResources = words(client.getAttribute("id-jag.resources"));
            for (String r : requestedResources) {
                if (allowedResources.contains(r) && !grantedResources.contains(r)) {
                    grantedResources.add(r);
                }
            }
            if (grantedResources.isEmpty()) {
                throw fail(cors, event, INVALID_TARGET, "none of the requested resources is allowed", Response.Status.BAD_REQUEST);
            }
        }

        // 6. Scopes (RFC 6749 section 3.3): grant the allowed subset.
        Set<String> allowedScopes = words(client.getAttribute("id-jag.scopes"));
        List<String> grantedScopes = new ArrayList<>();
        for (String s : words(ctx.getParams().getScope())) {
            if (allowedScopes.contains(s)) {
                grantedScopes.add(s);
            }
        }
        String scope = String.join(" ", grantedScopes);

        // 7. Build and sign the ID-JAG (RS256 with the realm's active key, published at jwks_uri).
        int lifespan = 300;
        try {
            String l = client.getAttribute("id-jag.lifespan");
            if (l != null && !l.isBlank()) {
                lifespan = Integer.parseInt(l.trim());
            }
        } catch (NumberFormatException ignored) {
        }
        String resourceClientId = client.getAttribute("id-jag.client-id");
        if (resourceClientId == null || resourceClientId.isBlank()) {
            resourceClientId = client.getClientId();
        }
        long now = Time.currentTime();
        Map<String, Object> claims = new LinkedHashMap<>();
        claims.put("iss", issuer);
        claims.put("sub", user.getId());
        claims.put("aud", aud);
        claims.put("client_id", resourceClientId.trim());
        claims.put("jti", UUID.randomUUID().toString());
        claims.put("iat", now);
        claims.put("exp", now + lifespan);
        if (!scope.isEmpty()) {
            claims.put("scope", scope);
        }
        if (grantedResources.size() == 1) {
            claims.put("resource", grantedResources.get(0));
        } else if (grantedResources.size() > 1) {
            claims.put("resource", grantedResources);
        }
        if (id.getAuth_time() != null) {
            claims.put("auth_time", id.getAuth_time());
        }
        if (id.getAcr() != null) {
            claims.put("acr", id.getAcr());
        }
        if (user.getEmail() != null) {
            claims.put("email", user.getEmail());
        }
        claims.put("preferred_username", user.getUsername());

        String idJag;
        try {
            SignatureProvider signer = session.getProvider(SignatureProvider.class, Algorithm.RS256);
            idJag = new JWSBuilder().type(ID_JAG_HEADER_TYPE).jsonContent(claims).sign(signer.signer());
        } catch (Exception e) {
            throw fail(cors, event, OAuthErrorException.SERVER_ERROR, "could not sign the ID-JAG (no active RS256 key?)",
                    Response.Status.INTERNAL_SERVER_ERROR);
        }

        // 8. Response, RFC 8693 section 2.2 with token_type N_A.
        Map<String, Object> res = new LinkedHashMap<>();
        res.put("access_token", idJag);
        res.put("issued_token_type", ID_JAG_TYPE);
        res.put("token_type", "N_A");
        res.put("expires_in", lifespan);
        if (!scope.isEmpty() || ctx.getParams().getScope() != null) {
            res.put("scope", scope);
        }
        event.detail("scope", scope);
        event.success();
        return cors.add(Response.ok(res, MediaType.APPLICATION_JSON_TYPE)
                .header("Cache-Control", "no-store")
                .header("Pragma", "no-cache"));
    }

    @Override
    public void close() {
    }

    private static Set<String> words(String s) {
        Set<String> out = new LinkedHashSet<>();
        if (s != null) {
            out.addAll(Arrays.asList(s.trim().split("\\s+")));
            out.remove("");
        }
        return out;
    }

    private static CorsErrorResponseException fail(Cors cors, EventBuilder event, String error, String description,
                                                   Response.Status status) {
        event.detail("reason", description);
        event.error(error);
        return new CorsErrorResponseException(cors, error, description, status);
    }
}
