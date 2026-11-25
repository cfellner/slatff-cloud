package cloud.slatff.idjag;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.protocol.oidc.TokenExchangeProviderFactory;

/**
 * Registers the ID-JAG issuer as a token exchange provider. Keycloak asks providers in
 * descending order; this one (20) is asked before standard token exchange (10) and only
 * takes requests with requested_token_type=urn:ietf:params:oauth:token-type:id-jag.
 */
public class IdJagTokenExchangeProviderFactory implements TokenExchangeProviderFactory {

    public static final String ID = "slatff-id-jag";

    @Override
    public TokenExchangeProvider create(KeycloakSession session) {
        return new IdJagTokenExchangeProvider();
    }

    @Override
    public void init(Config.Scope config) {
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
    }

    @Override
    public void close() {
    }

    @Override
    public String getId() {
        return ID;
    }

    @Override
    public int order() {
        return 20;
    }
}
