package com.litter.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.LoginAccountParams

/**
 * Account login/logout management for a specific server.
 */
@Composable
fun AccountSheet(
    serverId: String,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()

    val server = remember(snapshot, serverId) {
        snapshot?.servers?.find { it.serverId == serverId }
    }
    val account = server?.account
    var apiKey by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "Account",
            color = LitterTheme.textPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )

        Text(
            text = server?.displayName ?: serverId,
            color = LitterTheme.textSecondary,
            fontSize = 13.sp,
        )

        // Current account status
        when (account) {
            is Account.Chatgpt -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                        .padding(12.dp),
                ) {
                    Text("Logged in", color = LitterTheme.accent, fontSize = 13.sp)
                    Text(account.email, color = LitterTheme.textPrimary, fontSize = 14.sp)
                }
                if (server?.isLocal == true) {
                    OutlinedButton(
                        onClick = {
                            scope.launch {
                                appModel.rpc.logoutAccount(serverId)
                                appModel.refreshSnapshot()
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Logout")
                    }
                }
            }

            is Account.ApiKey -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                        .padding(12.dp),
                ) {
                    Text("API key configured", color = LitterTheme.accent, fontSize = 13.sp)
                }
                if (server?.isLocal == true) {
                    OutlinedButton(
                        onClick = {
                            scope.launch {
                                appModel.rpc.logoutAccount(serverId)
                                appModel.refreshSnapshot()
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Logout")
                    }
                }
            }

            else -> {
                if (server?.isLocal == true) {
                    Button(
                        onClick = {
                            scope.launch {
                                try {
                                    val resp = appModel.rpc.loginAccount(
                                        serverId,
                                        LoginAccountParams.Chatgpt,
                                    )
                                    if (resp is uniffi.codex_mobile_client.LoginAccountResponse.Chatgpt) {
                                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(resp.authUrl))
                                        context.startActivity(intent)
                                    }
                                } catch (e: Exception) {
                                    error = e.message
                                }
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = LitterTheme.accent,
                            contentColor = Color.Black,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Login with ChatGPT")
                    }

                    Text("Or use API key:", color = LitterTheme.textSecondary, fontSize = 12.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = apiKey,
                            onValueChange = { apiKey = it },
                            label = { Text("API Key") },
                            singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            modifier = Modifier.weight(1f),
                        )
                        Button(
                            onClick = {
                                scope.launch {
                                    try {
                                        appModel.rpc.loginAccount(
                                            serverId,
                                            LoginAccountParams.ApiKey(apiKey = apiKey.trim()),
                                        )
                                        appModel.refreshSnapshot()
                                        apiKey = ""
                                        error = null
                                    } catch (e: Exception) {
                                        error = e.message
                                    }
                                }
                            },
                            enabled = apiKey.isNotBlank(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = LitterTheme.accent,
                                contentColor = Color.Black,
                            ),
                        ) {
                            Text("Save")
                        }
                    }
                } else {
                    Text(
                        "Remote servers request their own OAuth login when needed. Account login and API key entry stay local-only.",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                    )
                }
            }
        }

        error?.let {
            Text(it, color = LitterTheme.danger, fontSize = 12.sp)
        }
    }
}
