//----------------------------------------------------------------------------- 
// <copyright file=CIEqualityComparer company="EMC Corporation">
//   Copyright (c) EMC Corporation. All Rights Reserved.
// </copyright>
// <author>Frederic Thevenet</author>
//----------------------------------------------------------------------------- 

using System;
using System.Collections.Generic;
using System.Text;
using System.Security.Cryptography;
using System.Globalization;

namespace dmqdocbroker
{
    /// <summary>
    /// Provides an implementation of IEqualityComparer for strings that is insensitive to case.
    /// </summary>
    public class CiEqualityComparer
            : EqualityComparer<string>
    {
        /// <summary>
        /// Determines whether the two specified strings are equal in case insensitive fashion.
        /// </summary>        
        /// <param name="x">The fist string to compare.</param>
        /// <param name="y">the second string to compare.</param>
        /// <returns>True is the two strings are equal, false otherwise.</returns>
        public override bool Equals(string x, string y)
        {
            if (x == null)
                throw new ArgumentNullException("x");

            if (y == null)
                throw new ArgumentNullException("y");

            return x.Equals(y, StringComparison.OrdinalIgnoreCase);
        }
    
        /// <summary>
        /// Returns the hash code for this string.
        /// </summary>
        /// <remarks>The same hash is returned regardless of the case of the string.</remarks>
        /// <param name="obj"></param>
        /// <returns></returns>
        public override int GetHashCode(string obj)
        {
            if (obj == null)
                throw new ArgumentNullException("obj");

            return obj.ToUpper(CultureInfo.InvariantCulture).GetHashCode();            
        }
    }
}
