import * as fs from "fs";
import { LanguageClient, RequestType } from "vscode-languageclient/node";
import { window } from "vscode";

interface CreateInterfaceRequestParams {
  uri: string;
}

let createInterfaceRequest = new RequestType<
  CreateInterfaceRequestParams,
  string,
  void
>("rescript-vscode.create_interface");

export const switchImplIntf = async (client: LanguageClient) => {
  if (!client) {
    return window.showInformationMessage("Language server not running");
  }

  const editor = window.activeTextEditor;

  if (!editor) {
    return window.showInformationMessage("No active editor");
  }

  const isIntf = editor.document.uri.path.endsWith(".resi");

  if (isIntf) {
		// *.res
    const newUri = editor.document.uri.with({
      path: editor.document.uri.path.slice(0, -1),
    });
    await window.showTextDocument(newUri, { preview: false });
    return;
  }

  if (!fs.existsSync(editor.document.uri.fsPath + "i")) {
		// if interface doesn't exist, create it.
    await client.sendRequest(createInterfaceRequest, {
      uri: editor.document.uri.toString(),
    });
  }

	// *.resi
  const newUri = editor.document.uri.with({
    path: editor.document.uri.path + "i",
  });
  await window.showTextDocument(newUri, { preview: false });
  return;
};
