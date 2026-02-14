// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPluginManager {
    event PluginInstalled(address indexed plugin);
    event PluginUninstalled(address indexed plugin);

    function installPlugin(address plugin, bytes calldata data) external;
    function uninstallPlugin(address plugin, bytes calldata data) external;
    function isPluginInstalled(address plugin) external view returns (bool);
    function listPlugins() external view returns (address[] memory);
}
