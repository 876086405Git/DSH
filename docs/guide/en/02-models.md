# Models and providers

Use a DeepSeek account or API key, or connect any OpenAI- or Anthropic-compatible service. When the engine supports it, you can also sign in with a ChatGPT or Claude subscription. For models in custom providers, set the context, image input and thinking levels yourself.

Providers are stored in the current host's engine. On a remote host, you manage that host's providers.

## Switch models and thinking effort

Tap the model capsule at the top right of a chat to open **Choose model**:

- With several providers, pick a provider at the top, then a model. Switching providers alone doesn't change the current model.
- Tapping a model takes effect at once. If the model has more than one level, **Thinking effort** appears below.

Typing `/model` in the composer opens it too.

## New chat defaults

<!-- nav: commonSettings,hubSettingsProviders -->
The top of `Settings › Models` shows **New chat defaults (last choice)**. The model and thinking effort are stored on the current host, not in a second global preference on the phone.

- **Last choice** is the default mode. Changing a chat's model or thinking effort makes the host remember that choice for newly created chats.
- **Fixed default** appears only on engines that support it. Temporary model changes in a chat no longer overwrite these defaults.
- Tap the model row, edit the model and thinking effort in the same model picker, then tap **Save**. Editing defaults here does not switch the current chat's model.

Saving confirms the host's complete resolved defaults. Editing is disabled when disconnected, read-only, settings cannot be read, or the settings schema is missing. If host base settings or another client make the read-back differ, the app says it could not confirm rather than claiming everything was saved. Older engines only offer the last-choice behavior, without fixed defaults or confirmation of persistence when switching a chat's model. On newer engines, a persistence failure says that the current chat's model changed but new chat defaults were not saved; the current chat keeps the new model.

Switching hosts or reconnecting reads that host's defaults again; unsubmitted choices do not carry over. A deleted model or unavailable provider may require another choice. Permissions keep their separate permission defaults and never inherit temporary session grants.

## Providers

<!-- nav: commonSettings,hubSettingsProviders -->
`Settings › Models` · [Open](dshgo://open/models)

Providers come in three groups:

- **Official**: DeepSeek. Tap it to open your account, where you sign in or enter an API key. On a remote host, this only shows whether that host is set up; configure it on that host.
- OpenAI under **Official**: shown only on a supported local Android engine. Sign in with ChatGPT in your browser and allow subscription usage, then choose a model available to that account. This is separate from ChatGPT (Codex) under Subscriptions; existing sign-ins and chats are not migrated. Manage usage and app access in [ChatGPT usage settings](https://chatgpt.com/settings/usage). After signing out, reconnect the same account to keep its app limits, or choose another account. Resetting the local engine does not sign you out of OpenAI; use this provider’s sign-out control to disconnect.
- **Subscriptions**: shown when the engine supports them and is connected. Tap **Sign in** and follow the steps in your browser. Open a signed-in subscription to see its models or **Sign out**, which removes its models from the model list.
- **Custom**: providers you add, plus ones configured in DSH Web or the engine's config file. Connect to the engine to add one.

## Add a custom provider

<!-- nav: commonSettings,hubSettingsProviders,engineProviderAdd -->
`Settings › Models › Add provider`

1. Under **Compatible protocol**, choose OpenAI, Anthropic or Responses, as the service's docs say.
2. Enter the Base URL and API key. A new provider needs an API key. **Name** is optional; it defaults to the domain in the URL.
3. Tap **Fetch models** and select the models you want. If the service lists none, tap **Add manually** and enter the **Model ID**.
4. Add at least one model, then tap **Save**.

Your new models now appear in **Choose model**.

## Model settings

On a custom provider's page, tap a model to adjust:

- **Name**: how it appears in the model list. Leave blank to use the model ID.
- **Context length**: 256K by default. Pick from 32K to 1M, or type a value such as 128K.
- **Max output**: 32K by default.
- **Input**: **Text**, or **Text + image** for models that can view images.
- **Thinking**: turn it on and choose **Available levels**. **Thinking effort** in chats then offers **Off** plus those levels. With Thinking off, the model has no effort choice.

On the provider's page, tap **Save** to apply right away. While adding or editing a provider, tap **Done**; the changes are saved with the provider.

## Test, edit and delete

Tap a provider in the list to open it:

- **Test connection**: reads the model list with the saved key. Uses no tokens.
- To edit, tap the pencil at the top right, or the API key row. Leave the API key blank to keep the saved one.
- **Delete provider**: deletes the provider and its API key. Chats using it will need another model.

Providers configured in DSH Web can only be viewed or deleted here. Providers from the engine's config file can't be deleted here.

## DeepSeek account and API key

Tap DeepSeek under **Official**, or the account card at the top of Settings:

- **Sign in with DeepSeek**: sign in with your browser. Needs DSH installed on this phone.
- **DeepSeek API key**: enter one if you haven't; otherwise **Replace key** or **Clear**. Clearing while this phone's engine is running deletes the engine's key too. If the engine isn't running, the engine keeps its key; remove it in DSH Web's model settings.
